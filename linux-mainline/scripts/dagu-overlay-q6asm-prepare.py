#!/usr/bin/env python3
"""Keep q6asm audio_client for the PCM fd lifetime.

Mainline q6asm_dai_prepare frees the client on OPEN_READ / OPEN_WRITE
failure. PipeWire spa.alsa stays in SETUP and retries prepare without
close/open. That is EINVAL + printk flood (~500 lines/s), journald pegged.

close() also skipped CMD_CLOSE unless state != IDLE, so a SIGINT during
arecord probe leaked the ADSP session (ADSP_EALREADY on the next OPEN).
"""
from __future__ import annotations

import sys
from pathlib import Path

root = Path(sys.argv[1])
path = root / "sound/soc/qcom/qdsp6/q6asm-dai.c"
text = path.read_text()
changed = False

PREPARE_MARKER = "dagu: keep audio_client across prepare fail"
CLOSE_MARKER = "dagu: always CMD_CLOSE — IDLE still leaks OPEN_READ"

PREPARE_NEW = '''static int q6asm_dai_prepare(struct snd_soc_component *component,
			     struct snd_pcm_substream *substream)
{
	struct snd_pcm_runtime *runtime = substream->runtime;
	struct snd_soc_pcm_runtime *soc_prtd = snd_soc_substream_to_rtd(substream);
	struct q6asm_dai_rtd *prtd = runtime->private_data;
	struct q6asm_dai_data *pdata;
	struct device *dev = component->dev;
	int ret, i, try;

	pdata = snd_soc_component_get_drvdata(component);
	if (!pdata)
		return -EINVAL;

	if (!prtd || !prtd->audio_client) {
		dev_err_ratelimited(dev,
			"%s: private data null or audio client freed\\n",
			__func__);
		return -EINVAL;
	}

	prtd->pcm_count = snd_pcm_lib_period_bytes(substream);
	/*
	 * STOPPED still has an ASM session (TRIGGER_STOP only sends EOS).
	 * A failed previous prepare may have OPEN_READ without RUNNING.
	 * Re-prepare must CLOSE first or DSP returns ADSP_EALREADY (9).
	 * dagu: keep audio_client across prepare fail
	 */
	if (prtd->state != Q6ASM_STREAM_IDLE) {
		q6asm_cmd(prtd->audio_client, prtd->stream_id, CMD_CLOSE);
		q6asm_unmap_memory_regions(substream->stream,
					   prtd->audio_client);
		q6routing_stream_close(soc_prtd->dai_link->id,
				       substream->stream);
		prtd->state = Q6ASM_STREAM_IDLE;
	}

	ret = q6asm_map_memory_regions(substream->stream, prtd->audio_client,
				       prtd->phys,
				       (prtd->pcm_size / prtd->periods),
				       prtd->periods);
	if (ret < 0) {
		dev_err_ratelimited(dev,
			"Audio Start: Buffer Allocation failed rc = %d\\n",
			ret);
		return -ENOMEM;
	}

	ret = -EINVAL;
	for (try = 0; try < 2; try++) {
		if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK)
			ret = q6asm_open_write(prtd->audio_client,
					       prtd->stream_id,
					       FORMAT_LINEAR_PCM, 0,
					       prtd->bits_per_sample, false);
		else if (substream->stream == SNDRV_PCM_STREAM_CAPTURE)
			ret = q6asm_open_read(prtd->audio_client,
					      prtd->stream_id,
					      FORMAT_LINEAR_PCM,
					      prtd->bits_per_sample);
		if (ret >= 0)
			break;
		q6asm_cmd(prtd->audio_client, prtd->stream_id, CMD_CLOSE);
	}

	if (ret < 0) {
		dev_err_ratelimited(dev, "%s: q6asm_open_write failed\\n",
				    __func__);
		goto open_err;
	}

	prtd->session_id = q6asm_get_session_id(prtd->audio_client);
	ret = q6routing_stream_open(soc_prtd->dai_link->id, LEGACY_PCM_MODE,
			      prtd->session_id, substream->stream);
	if (ret) {
		dev_err_ratelimited(dev, "%s: stream reg failed ret:%d\\n",
				    __func__, ret);
		goto routing_err;
	}

	if (substream->stream == SNDRV_PCM_STREAM_PLAYBACK) {
		ret = q6asm_media_format_block_multi_ch_pcm(
				prtd->audio_client, prtd->stream_id,
				runtime->rate, runtime->channels, NULL,
				prtd->bits_per_sample);
	} else if (substream->stream == SNDRV_PCM_STREAM_CAPTURE) {
		ret = q6asm_enc_cfg_blk_pcm_format_support(prtd->audio_client,
							   prtd->stream_id,
							   runtime->rate,
							   runtime->channels,
							   prtd->bits_per_sample);
		if (ret >= 0) {
			for (i = 0; i < runtime->periods; i++)
				q6asm_read(prtd->audio_client, prtd->stream_id);
		}
	}
	if (ret < 0) {
		dev_err_ratelimited(dev, "%s: CMD Format block failed\\n",
				    __func__);
		goto routing_err;
	}

	prtd->state = Q6ASM_STREAM_RUNNING;
	return 0;

routing_err:
	q6asm_cmd(prtd->audio_client, prtd->stream_id, CMD_CLOSE);
	q6routing_stream_close(soc_prtd->dai_link->id, substream->stream);
open_err:
	q6asm_unmap_memory_regions(substream->stream, prtd->audio_client);
	prtd->state = Q6ASM_STREAM_IDLE;
	return ret;
}

'''

if PREPARE_MARKER not in text:
    start = text.find("static int q6asm_dai_prepare(struct snd_soc_component *component,")
    end = text.find("static int q6asm_dai_ack(struct snd_soc_component *component,")
    if start < 0 or end < 0 or end <= start:
        raise SystemExit(f"{path}: q6asm_dai_prepare bounds missing")
    text = text[:start] + PREPARE_NEW + text[end:]
    changed = True
    print(f"patched {path}: {PREPARE_MARKER}")

old_close = """	if (prtd->audio_client) {
		if (prtd->state)
			q6asm_cmd(prtd->audio_client, prtd->stream_id,
				  CMD_CLOSE);

		q6asm_unmap_memory_regions(substream->stream,
					   prtd->audio_client);
"""
new_close = """	if (prtd->audio_client) {
		/* dagu: always CMD_CLOSE — IDLE still leaks OPEN_READ */
		q6asm_cmd(prtd->audio_client, prtd->stream_id, CMD_CLOSE);

		q6asm_unmap_memory_regions(substream->stream,
					   prtd->audio_client);
"""
if old_close in text:
    text = text.replace(old_close, new_close, 1)
    changed = True
    print(f"patched {path}: PCM {CLOSE_MARKER}")

old_compr_free = """	if (prtd->audio_client) {
		if (prtd->state) {
			q6asm_cmd(prtd->audio_client, prtd->stream_id,
				  CMD_CLOSE);
			if (prtd->next_track_stream_id) {
				q6asm_cmd(prtd->audio_client,
					  prtd->next_track_stream_id,
					  CMD_CLOSE);
			}
		}
"""
new_compr_free = """	if (prtd->audio_client) {
		/* dagu: always CMD_CLOSE — IDLE still leaks OPEN_READ */
		q6asm_cmd(prtd->audio_client, prtd->stream_id, CMD_CLOSE);
		if (prtd->next_track_stream_id)
			q6asm_cmd(prtd->audio_client,
				  prtd->next_track_stream_id, CMD_CLOSE);
"""
if old_compr_free in text:
    text = text.replace(old_compr_free, new_compr_free, 1)
    changed = True
    print(f"patched {path}: compr {CLOSE_MARKER}")

old_null = """	if (!prtd || !prtd->audio_client) {
		dev_err(dev, "private data null or audio client freed\\n");
		return -EINVAL;
	}
"""
new_null = """	if (!prtd || !prtd->audio_client) {
		dev_err_ratelimited(dev,
			"private data null or audio client freed\\n");
		return -EINVAL;
	}
"""
if old_null in text:
    text = text.replace(old_null, new_null, 1)
    changed = True
    print(f"patched {path}: compr null ratelimit")

old_compr_err = """q6_err:
	q6asm_cmd(prtd->audio_client, prtd->stream_id, CMD_CLOSE);

open_err:
	q6asm_audio_client_free(prtd->audio_client);
	prtd->audio_client = NULL;
	return ret;
}
"""
new_compr_err = """q6_err:
	q6asm_cmd(prtd->audio_client, prtd->stream_id, CMD_CLOSE);

open_err:
	/* dagu: keep audio_client across prepare fail */
	prtd->state = Q6ASM_STREAM_IDLE;
	return ret;
}
"""
if old_compr_err in text:
    text = text.replace(old_compr_err, new_compr_err, 1)
    changed = True
    print(f"patched {path}: compr keep audio_client")

if changed:
    path.write_text(text)

text = path.read_text()
if PREPARE_MARKER not in text:
    raise SystemExit(f"{path}: {PREPARE_MARKER} missing")
if CLOSE_MARKER not in text:
    raise SystemExit(f"{path}: {CLOSE_MARKER} missing")
fn = text[text.find("static int q6asm_dai_prepare("):
          text.find("static int q6asm_dai_ack(")]
if "q6asm_audio_client_free" in fn:
    raise SystemExit(f"{path}: prepare still frees audio_client on error")
print("dagu-overlay-q6asm-prepare: ok")
