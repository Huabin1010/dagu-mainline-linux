#!/usr/bin/env python3
"""Replay ADSP voice / A2DP topology onto the live kernel tree.

Android speaker-mic Fluence is ADM SM ECNS V2 (0x10F89) + module 0x10F31
param 0x10EAF AEC|NS, echo ref = TERT_TDM_RX_0 (playback already clocked).
A2DP backend is AFE SLIMBUS_7_RX 0x400e (CAF apr_audio-v2.h).
"""
from __future__ import annotations

import sys
from pathlib import Path

root = Path(sys.argv[1])


def patch(rel: str, marker: str, old: str, new: str) -> None:
    path = root / rel
    text = path.read_text()
    if marker in text:
        return
    if old not in text:
        raise SystemExit(f"{path}: needle missing for {marker}")
    path.write_text(text.replace(old, new, 1))
    print(f"patched {path}: {marker}")


# Virtual DAI ids after USB_RX=136. RX even / TX odd so q6slim_set_channel_map
# (dai->id & 1) still matches CAF SLIMBUS_0_RX even.
patch(
    "include/dt-bindings/sound/qcom,q6dsp-lpass-ports.h",
    "dagu: SLIMBUS_7 virtual ports",
    "#define USB_RX			136\n",
    """#define USB_RX			136
/* dagu: SLIMBUS_7 virtual ports — AFE 0x400e/0x400f, not a physical SLIMbus. */
#define SLIMBUS_7_RX		138
#define SLIMBUS_7_TX		139

""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe.h",
    "dagu: AFE_PORT_MAX includes SLIMBUS_7",
    "#define AFE_PORT_MAX		137\n",
    "#define AFE_PORT_MAX		140 /* dagu: AFE_PORT_MAX includes SLIMBUS_7 */\n",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe.c",
    "dagu: AFE SLIMBUS_7 port ids",
    "#define AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_TX      0x400d\n",
    """#define AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_TX      0x400d
#define AFE_PORT_ID_SLIMBUS_MULTI_CHAN_7_RX      0x400e /* dagu: AFE SLIMBUS_7 port ids */
#define AFE_PORT_ID_SLIMBUS_MULTI_CHAN_7_TX      0x400f
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe.c",
    "dagu: map SLIMBUS_7 into port_maps",
    """	[SLIMBUS_6_TX] = { AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_TX,
				SLIMBUS_6_TX, 0, 1},
""",
    """	[SLIMBUS_6_TX] = { AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_TX,
				SLIMBUS_6_TX, 0, 1},
	/* dagu: map SLIMBUS_7 into port_maps */
	[SLIMBUS_7_RX] = { AFE_PORT_ID_SLIMBUS_MULTI_CHAN_7_RX,
				SLIMBUS_7_RX, 1, 1},
	[SLIMBUS_7_TX] = { AFE_PORT_ID_SLIMBUS_MULTI_CHAN_7_TX,
				SLIMBUS_7_TX, 0, 1},
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6dsp-lpass-ports.c",
    "dagu: SLIMBUS_7 DAI drivers",
    """		.name = "SLIMBUS_6_TX",
		.id = SLIMBUS_6_TX,
		.capture = {
			.stream_name = "Slimbus6 Capture",
			.rates = SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_8000 |
				 SNDRV_PCM_RATE_16000 | SNDRV_PCM_RATE_96000 |
				 SNDRV_PCM_RATE_192000,
			.formats = SNDRV_PCM_FMTBIT_S16_LE |
				   SNDRV_PCM_FMTBIT_S24_LE,
			.channels_min = 1,
			.channels_max = 8,
			.rate_min = 8000,
			.rate_max = 192000,
		},
	}, {
		.playback = {
			.stream_name = "Primary MI2S Playback",
""",
    """		.name = "SLIMBUS_6_TX",
		.id = SLIMBUS_6_TX,
		.capture = {
			.stream_name = "Slimbus6 Capture",
			.rates = SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_8000 |
				 SNDRV_PCM_RATE_16000 | SNDRV_PCM_RATE_96000 |
				 SNDRV_PCM_RATE_192000,
			.formats = SNDRV_PCM_FMTBIT_S16_LE |
				   SNDRV_PCM_FMTBIT_S24_LE,
			.channels_min = 1,
			.channels_max = 8,
			.rate_min = 8000,
			.rate_max = 192000,
		},
	}, {
		/* dagu: SLIMBUS_7 DAI drivers */
		.playback = {
			.stream_name = "Slimbus7 Playback",
			.rates = SNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_16000 |
				 SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_96000 |
				 SNDRV_PCM_RATE_192000,
			.formats = SNDRV_PCM_FMTBIT_S16_LE |
				   SNDRV_PCM_FMTBIT_S24_LE,
			.channels_min = 1,
			.channels_max = 2,
			.rate_min = 8000,
			.rate_max = 192000,
		},
		.name = "SLIMBUS_7_RX",
		.id = SLIMBUS_7_RX,
	}, {
		.name = "SLIMBUS_7_TX",
		.id = SLIMBUS_7_TX,
		.capture = {
			.stream_name = "Slimbus7 Capture",
			.rates = SNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_16000 |
				 SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_96000 |
				 SNDRV_PCM_RATE_192000,
			.formats = SNDRV_PCM_FMTBIT_S16_LE |
				   SNDRV_PCM_FMTBIT_S24_LE,
			.channels_min = 1,
			.channels_max = 2,
			.rate_min = 8000,
			.rate_max = 192000,
		},
	}, {
		.playback = {
			.stream_name = "Primary MI2S Playback",
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6dsp-lpass-ports.c",
    "dagu: SLIMBUS_7 uses slim ops",
    """		case SLIMBUS_0_RX ... SLIMBUS_6_TX:
			q6dsp_audio_fe_dais[i].ops = cfg->q6slim_ops;
			break;
""",
    """		case SLIMBUS_0_RX ... SLIMBUS_6_TX:
		case SLIMBUS_7_RX:
		case SLIMBUS_7_TX:
			/* dagu: SLIMBUS_7 uses slim ops */
			q6dsp_audio_fe_dais[i].ops = cfg->q6slim_ops;
			break;
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe-dai.c",
    "dagu: prepare SLIMBUS_7 slim cfg",
    """	case SLIMBUS_0_RX ... SLIMBUS_6_TX:
		q6afe_slim_port_prepare(dai_data->port[dai->id],
					&dai_data->port_config[dai->id].slim);
		break;
""",
    """	case SLIMBUS_0_RX ... SLIMBUS_6_TX:
	case SLIMBUS_7_RX:
	case SLIMBUS_7_TX:
		/* dagu: prepare SLIMBUS_7 slim cfg */
		q6afe_slim_port_prepare(dai_data->port[dai->id],
					&dai_data->port_config[dai->id].slim);
		break;
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe-dai.c",
    "dagu: SLIMBUS_7 DAPM routes",
    """	{"Slimbus6 Playback", NULL, "SLIMBUS_6_RX"},

	{"SLIMBUS_0_TX", NULL, "Slimbus Capture"},
""",
    """	{"Slimbus6 Playback", NULL, "SLIMBUS_6_RX"},
	{"Slimbus7 Playback", NULL, "SLIMBUS_7_RX"}, /* dagu: SLIMBUS_7 DAPM routes */

	{"SLIMBUS_0_TX", NULL, "Slimbus Capture"},
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe-dai.c",
    "dagu: SLIMBUS_7 TX DAPM route",
    """	{"SLIMBUS_6_TX", NULL, "Slimbus6 Capture"},

	{"Primary MI2S Playback", NULL, "PRI_MI2S_RX"},
""",
    """	{"SLIMBUS_6_TX", NULL, "Slimbus6 Capture"},
	{"SLIMBUS_7_TX", NULL, "Slimbus7 Capture"}, /* dagu: SLIMBUS_7 TX DAPM route */

	{"Primary MI2S Playback", NULL, "PRI_MI2S_RX"},
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe-dai.c",
    "dagu: SLIMBUS_7 DAPM widgets",
    """	SND_SOC_DAPM_AIF_IN("SLIMBUS_6_RX", NULL, 0, SND_SOC_NOPM, 0, 0),
	SND_SOC_DAPM_AIF_OUT("SLIMBUS_0_TX", NULL, 0, SND_SOC_NOPM, 0, 0),
""",
    """	SND_SOC_DAPM_AIF_IN("SLIMBUS_6_RX", NULL, 0, SND_SOC_NOPM, 0, 0),
	SND_SOC_DAPM_AIF_IN("SLIMBUS_7_RX", NULL, 0, SND_SOC_NOPM, 0, 0), /* dagu: SLIMBUS_7 DAPM widgets */
	SND_SOC_DAPM_AIF_OUT("SLIMBUS_0_TX", NULL, 0, SND_SOC_NOPM, 0, 0),
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe-dai.c",
    "dagu: SLIMBUS_7 TX widget",
    """	SND_SOC_DAPM_AIF_OUT("SLIMBUS_6_TX", NULL, 0, SND_SOC_NOPM, 0, 0),
	SND_SOC_DAPM_AIF_IN("QUIN_MI2S_RX", NULL,
""",
    """	SND_SOC_DAPM_AIF_OUT("SLIMBUS_6_TX", NULL, 0, SND_SOC_NOPM, 0, 0),
	SND_SOC_DAPM_AIF_OUT("SLIMBUS_7_TX", NULL, 0, SND_SOC_NOPM, 0, 0), /* dagu: SLIMBUS_7 TX widget */
	SND_SOC_DAPM_AIF_IN("QUIN_MI2S_RX", NULL,
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: SLIMBUS_7 RX mixer controls",
    """static const struct snd_kcontrol_new slimbus_6_rx_mixer_controls[] = {
	Q6ROUTING_RX_MIXERS(SLIMBUS_6_RX) };
""",
    """static const struct snd_kcontrol_new slimbus_6_rx_mixer_controls[] = {
	Q6ROUTING_RX_MIXERS(SLIMBUS_6_RX) };

static const struct snd_kcontrol_new slimbus_7_rx_mixer_controls[] = {
	/* dagu: SLIMBUS_7 RX mixer controls */
	Q6ROUTING_RX_MIXERS(SLIMBUS_7_RX) };
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: SLIMBUS_7 RX mixer widget",
    """	SND_SOC_DAPM_MIXER("SLIMBUS_6_RX Audio Mixer", SND_SOC_NOPM, 0, 0,
			   slimbus_6_rx_mixer_controls,
			   ARRAY_SIZE(slimbus_6_rx_mixer_controls)),
""",
    """	SND_SOC_DAPM_MIXER("SLIMBUS_6_RX Audio Mixer", SND_SOC_NOPM, 0, 0,
			   slimbus_6_rx_mixer_controls,
			   ARRAY_SIZE(slimbus_6_rx_mixer_controls)),
	SND_SOC_DAPM_MIXER("SLIMBUS_7_RX Audio Mixer", SND_SOC_NOPM, 0, 0,
			   slimbus_7_rx_mixer_controls,
			   ARRAY_SIZE(slimbus_7_rx_mixer_controls)), /* dagu: SLIMBUS_7 RX mixer widget */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: SLIMBUS_7 RX DAPM route",
    """	Q6ROUTING_RX_DAPM_ROUTE("SLIMBUS_6_RX Audio Mixer", "SLIMBUS_6_RX"),
""",
    """	Q6ROUTING_RX_DAPM_ROUTE("SLIMBUS_6_RX Audio Mixer", "SLIMBUS_6_RX"),
	Q6ROUTING_RX_DAPM_ROUTE("SLIMBUS_7_RX Audio Mixer", "SLIMBUS_7_RX"), /* dagu: SLIMBUS_7 RX DAPM route */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.h",
    "dagu: Fluence COPP + q6adm_open ec_ref",
    """#define NULL_COPP_TOPOLOGY	0x00010312
""",
    """#define NULL_COPP_TOPOLOGY	0x00010312
/* dagu: Fluence COPP + q6adm_open ec_ref */
/* CAF apr_audio-v2.h: single-mic ECNS V2. Android speaker-mic AEC/NS. */
#define VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY	0x00010F89
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.h",
    "dagu: q6adm_open ec_ref argument",
    """struct q6copp *q6adm_open(struct device *dev, int port_id, int path, int rate,
			   int channel_mode, int topology, int perf_mode,
			   uint16_t bit_width, int app_type, int acdb_id);
""",
    """struct q6copp *q6adm_open(struct device *dev, int port_id, int path, int rate,
			   int channel_mode, int topology, int perf_mode,
			   uint16_t bit_width, int app_type, int acdb_id,
			   int ec_ref_idx); /* dagu: q6adm_open ec_ref argument */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: ADM SET_PP_PARAMS + Fluence module",
    """#define ADM_CMD_DEVICE_OPEN_V5		0x00010326
#define ADM_CMDRSP_DEVICE_OPEN_V5	0x00010329
#define ADM_CMD_DEVICE_CLOSE_V5		0x00010327
#define ADM_CMD_MATRIX_MAP_ROUTINGS_V5	0x00010325
""",
    """#define ADM_CMD_DEVICE_OPEN_V5		0x00010326
#define ADM_CMDRSP_DEVICE_OPEN_V5	0x00010329
#define ADM_CMD_DEVICE_CLOSE_V5		0x00010327
#define ADM_CMD_MATRIX_MAP_ROUTINGS_V5	0x00010325
#define ADM_CMD_SET_PP_PARAMS_V5	0x00010323 /* dagu: ADM SET_PP_PARAMS + Fluence module */
#define AUDPROC_MODULE_ID_FLUENCE_SMECNS	0x00010F31
#define FLUENCE_CMN_GLOBAL_EFFECT_PARAM_ID	0x00010EAF
#define FLUENCE_EFFECT_AEC			BIT(0)
#define FLUENCE_EFFECT_NS			BIT(1)
#define AFE_PORT_INVALID		0xFFFF
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: wake SET_PP_PARAMS",
    """		switch (result->opcode) {
		case ADM_CMD_DEVICE_OPEN_V5:
		case ADM_CMD_DEVICE_CLOSE_V5:
""",
    """		switch (result->opcode) {
		case ADM_CMD_DEVICE_OPEN_V5:
		case ADM_CMD_DEVICE_CLOSE_V5:
		case ADM_CMD_SET_PP_PARAMS_V5:
			/* dagu: wake SET_PP_PARAMS */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: Fluence EC ref + PP params",
    """static int q6adm_device_open(struct q6adm *adm, struct q6copp *copp,
			     int port_id, int path, int topology,
			     int channel_mode, int bit_width, int rate)
{
	struct q6adm_cmd_device_open_v5 *open;
	int afe_port = q6afe_get_port_id(port_id);
	struct apr_pkt *pkt;
	int ret, pkt_size = APR_HDR_SIZE + sizeof(*open);
""",
    """/* dagu: Fluence EC ref + PP params */
static int q6adm_set_fluence_effect(struct q6adm *adm, struct q6copp *copp,
				    int port_id)
{
	struct {
		struct apr_hdr hdr;
		u32 payload_addr_lsw;
		u32 payload_addr_msw;
		u32 mem_map_handle;
		u32 payload_size;
		u32 module_id;
		u32 param_id;
		u16 param_size;
		u16 reserved;
		u32 value;
	} __packed pkt;
	int afe_port = q6afe_get_port_id(port_id);

	memset(&pkt, 0, sizeof(pkt));
	pkt.hdr.hdr_field = APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD,
					  APR_HDR_LEN(APR_HDR_SIZE),
					  APR_PKT_VER);
	pkt.hdr.pkt_size = sizeof(pkt);
	pkt.hdr.src_port = afe_port;
	pkt.hdr.dest_port = copp->id;
	pkt.hdr.token = port_id << 16 | copp->copp_idx;
	pkt.hdr.opcode = ADM_CMD_SET_PP_PARAMS_V5;
	pkt.payload_size = 16;
	pkt.module_id = AUDPROC_MODULE_ID_FLUENCE_SMECNS;
	pkt.param_id = FLUENCE_CMN_GLOBAL_EFFECT_PARAM_ID;
	pkt.param_size = sizeof(pkt.value);
	pkt.value = FLUENCE_EFFECT_AEC | FLUENCE_EFFECT_NS;

	return q6adm_apr_send_copp_pkt(adm, copp, (struct apr_pkt *)&pkt, 0);
}

static int q6adm_device_open(struct q6adm *adm, struct q6copp *copp,
			     int port_id, int path, int topology,
			     int channel_mode, int bit_width, int rate,
			     int ec_ref_idx)
{
	struct q6adm_cmd_device_open_v5 *open;
	int afe_port = q6afe_get_port_id(port_id);
	struct apr_pkt *pkt;
	int ret, pkt_size = APR_HDR_SIZE + sizeof(*open);
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: fill endpoint_id_2 for Fluence",
    """	open->flags = ADM_LEGACY_DEVICE_SESSION;
	open->mode_of_operation = path;
	open->endpoint_id_1 = afe_port;
	open->topology_id = topology;
""",
    """	open->flags = ADM_LEGACY_DEVICE_SESSION;
	open->mode_of_operation = path;
	open->endpoint_id_1 = afe_port;
	/* dagu: fill endpoint_id_2 for Fluence */
	if (ec_ref_idx > 0) {
		int ec = q6afe_get_port_id(ec_ref_idx);

		open->endpoint_id_2 = (ec > 0) ? ec : AFE_PORT_INVALID;
	} else {
		open->endpoint_id_2 = AFE_PORT_INVALID;
	}
	open->topology_id = topology;
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: q6adm_open passes ec_ref and Fluence PP",
    """struct q6copp *q6adm_open(struct device *dev, int port_id, int path, int rate,
	       int channel_mode, int topology, int perf_mode,
	       uint16_t bit_width, int app_type, int acdb_id)
{
""",
    """struct q6copp *q6adm_open(struct device *dev, int port_id, int path, int rate,
	       int channel_mode, int topology, int perf_mode,
	       uint16_t bit_width, int app_type, int acdb_id, int ec_ref_idx)
{ /* dagu: q6adm_open passes ec_ref and Fluence PP */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: device_open with ec_ref then Fluence PP",
    """	ret = q6adm_device_open(adm, copp, port_id, path, topology,
				channel_mode, bit_width, rate);
	if (ret < 0) {
		kref_put(&copp->refcount, q6adm_free_copp);
		return ERR_PTR(ret);
	}

	return copp;
}
""",
    """	ret = q6adm_device_open(adm, copp, port_id, path, topology,
				channel_mode, bit_width, rate, ec_ref_idx);
	if (ret < 0) {
		kref_put(&copp->refcount, q6adm_free_copp);
		return ERR_PTR(ret);
	}

	/* dagu: device_open with ec_ref then Fluence PP */
	if (topology == VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY) {
		ret = q6adm_set_fluence_effect(adm, copp, port_id);
		dev_info(dev, "dagu fluence topo=0x%x ec_idx=%d pp=%d copp=%d\\n",
			 topology, ec_ref_idx, ret, copp->id);
		if (ret)
			dev_warn(dev, "dagu fluence PP params failed (%d); COPP still open\\n",
				 ret);
	}

	return copp;
}
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: Fluence mixer + COPP on capture",
    """static int msm_routing_probe(struct snd_soc_component *c)
{
""",
    """/* dagu: Fluence mixer + COPP on capture */
static int dagu_fluence_get(struct snd_kcontrol *kcontrol,
			    struct snd_ctl_elem_value *ucontrol)
{
	ucontrol->value.enumerated.item[0] = dagu_fluence_aec_ns;
	return 0;
}

static int dagu_fluence_put(struct snd_kcontrol *kcontrol,
			    struct snd_ctl_elem_value *ucontrol)
{
	unsigned int item = ucontrol->value.enumerated.item[0];

	dagu_fluence_aec_ns = item ? 1 : 0;
	return 1;
}

static const char * const dagu_fluence_texts[] = { "Off", "AEC_NS" };
static const struct soc_enum dagu_fluence_enum =
	SOC_ENUM_SINGLE_EXT(ARRAY_SIZE(dagu_fluence_texts), dagu_fluence_texts);

static const struct snd_kcontrol_new dagu_routing_controls[] = {
	SOC_ENUM_EXT("Fluence AEC NS", dagu_fluence_enum,
		     dagu_fluence_get, dagu_fluence_put),
};

static int msm_routing_probe(struct snd_soc_component *c)
{
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: attach Fluence controls",
    """static const struct snd_soc_component_driver msm_soc_routing_component = {
	.probe = msm_routing_probe,
	.name = DRV_NAME,
	.hw_params = routing_hw_params,
	.dapm_widgets = msm_qdsp6_widgets,
	.num_dapm_widgets = ARRAY_SIZE(msm_qdsp6_widgets),
	.dapm_routes = intercon,
	.num_dapm_routes = ARRAY_SIZE(intercon),
	.read = q6routing_reg_read,
	.write = q6routing_reg_write,
};
""",
    """static const struct snd_soc_component_driver msm_soc_routing_component = {
	.probe = msm_routing_probe,
	.name = DRV_NAME,
	.hw_params = routing_hw_params,
	.controls = dagu_routing_controls, /* dagu: attach Fluence controls */
	.num_controls = ARRAY_SIZE(dagu_routing_controls),
	.dapm_widgets = msm_qdsp6_widgets,
	.num_dapm_widgets = ARRAY_SIZE(msm_qdsp6_widgets),
	.dapm_routes = intercon,
	.num_dapm_routes = ARRAY_SIZE(intercon),
	.read = q6routing_reg_read,
	.write = q6routing_reg_write,
};
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: open Fluence COPP on capture",
    """	payload.num_copps = 0; /* only RX needs to use payload */
	topology = NULL_COPP_TOPOLOGY;
	copp = q6adm_open(routing_data->dev, session->port_id,
			      session->path_type, session->sample_rate,
			      session->channels, topology, perf_mode,
			      session->bits_per_sample, 0, 0);

	if (IS_ERR_OR_NULL(copp)) {
		mutex_unlock(&routing_data->lock);
		return -EINVAL;
	}
""",
    """	payload.num_copps = 0; /* only RX needs to use payload */
	topology = NULL_COPP_TOPOLOGY;
	{
		int ec_ref = 0;

		/* dagu: open Fluence COPP on capture */
		if (session->path_type == ADM_PATH_LIVE_REC && dagu_fluence_aec_ns &&
		    session->port_id == TX_CODEC_DMA_TX_3) {
			topology = VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY;
			ec_ref = TERTIARY_TDM_RX_0;
		}
		copp = q6adm_open(routing_data->dev, session->port_id,
				  session->path_type, session->sample_rate,
				  session->channels, topology, perf_mode,
				  session->bits_per_sample, 0, 0, ec_ref);
		if (IS_ERR_OR_NULL(copp) && topology != NULL_COPP_TOPOLOGY) {
			dev_warn(routing_data->dev,
				 "dagu fluence topo 0x%x failed, NULL_COPP\\n",
				 topology);
			topology = NULL_COPP_TOPOLOGY;
			copp = q6adm_open(routing_data->dev, session->port_id,
					  session->path_type, session->sample_rate,
					  session->channels, topology, perf_mode,
					  session->bits_per_sample, 0, 0, 0);
		}
	}

	if (IS_ERR_OR_NULL(copp)) {
		mutex_unlock(&routing_data->lock);
		return -EINVAL;
	}
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: Fluence AEC NS flag",
    '#define DRV_NAME "q6routing-component"\n',
    """#define DRV_NAME "q6routing-component"

static int dagu_fluence_aec_ns; /* dagu: Fluence AEC NS flag */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6afe.c",
    "dagu: SLIMBUS_7 AFE cfg",
    """	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_TX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_0_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_1_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_2_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_3_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_4_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_5_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_RX:
		cfg_type = AFE_PARAM_ID_SLIMBUS_CONFIG;
""",
    """	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_TX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_7_TX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_0_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_1_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_2_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_3_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_4_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_5_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_6_RX:
	case AFE_PORT_ID_SLIMBUS_MULTI_CHAN_7_RX: /* dagu: SLIMBUS_7 AFE cfg */
		cfg_type = AFE_PARAM_ID_SLIMBUS_CONFIG;
""",
)

patch(
    "sound/soc/qcom/sm8250.c",
    "dagu: SLIMBUS_7 A2DP channel map",
    """	default:
		break;
	}

	return qcom_snd_sdw_startup(substream);
""",
    """	case SLIMBUS_7_RX: {
		static const unsigned int rx_slots[] = { 0, 1 };

		/* dagu: SLIMBUS_7 A2DP channel map */
		snd_soc_dai_set_channel_map(cpu_dai, 0, NULL,
					    ARRAY_SIZE(rx_slots), rx_slots);
		break;
	}
	case SLIMBUS_7_TX: {
		static const unsigned int tx_slots[] = { 0, 1 };

		snd_soc_dai_set_channel_map(cpu_dai, ARRAY_SIZE(tx_slots),
					    tx_slots, 0, NULL);
		break;
	}
	default:
		break;
	}

	return qcom_snd_sdw_startup(substream);
""",
)

# --- follow-up: CAF OPEN_V8 + echo-ref ep2 (post V5 Fluence overlay) ---
patch(
    "sound/soc/qcom/qdsp6/q6adm.h",
    "dagu: SM ECNS V1 fallback",
    """#define VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY	0x00010F89
""",
    """#define VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY	0x00010F89
#define VPM_TX_SM_ECNS_COPP_TOPOLOGY	0x00010F71 /* dagu: SM ECNS V1 fallback */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: CAF ADM open v8",
    """#define ADM_CMD_DEVICE_OPEN_V5		0x00010326
#define ADM_CMDRSP_DEVICE_OPEN_V5	0x00010329
#define ADM_CMD_DEVICE_CLOSE_V5		0x00010327
#define ADM_CMD_MATRIX_MAP_ROUTINGS_V5	0x00010325
#define ADM_CMD_SET_PP_PARAMS_V5	0x00010323 /* dagu: ADM SET_PP_PARAMS + Fluence module */
""",
    """#define ADM_CMD_DEVICE_OPEN_V5		0x00010326
#define ADM_CMDRSP_DEVICE_OPEN_V5	0x00010329
#define ADM_CMD_DEVICE_OPEN_V8		0x0001036A /* dagu: CAF ADM open v8 */
#define ADM_CMDRSP_DEVICE_OPEN_V8	0x0001036B
#define ADM_CMD_DEVICE_CLOSE_V5		0x00010327
#define ADM_CMD_MATRIX_MAP_ROUTINGS_V5	0x00010325
#define ADM_CMD_SET_PP_PARAMS_V5	0x00010328 /* dagu: ADM SET_PP_PARAMS + Fluence module */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "CAF apr_audio-v2.h ADM_CMD_DEVICE_OPEN_V8",
    """} __packed;

struct q6adm_cmd_matrix_map_routings_v5 {
""",
    """} __packed;

/* CAF apr_audio-v2.h ADM_CMD_DEVICE_OPEN_V8 — echo ref has its own ep payload. */
struct q6adm_cmd_device_open_v8 {
	u16 flags;
	u16 mode_of_operation;
	u32 topology_id;
	u16 endpoint_id_1;
	u16 endpoint_id_2;
	u16 endpoint_id_3;
	u16 compressed_data_type;
} __packed;

struct q6adm_device_endpoint_payload {
	u16 dev_num_channel;
	u16 bit_width;
	u32 sample_rate;
	u8 dev_channel_mapping[32];
} __packed;

struct q6adm_cmd_matrix_map_routings_v5 {
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: wake SET_PP_PARAMS / OPEN_V8",
    """		case ADM_CMD_DEVICE_OPEN_V5:
		case ADM_CMD_DEVICE_CLOSE_V5:
		case ADM_CMD_SET_PP_PARAMS_V5:
			/* dagu: wake SET_PP_PARAMS */
""",
    """		case ADM_CMD_DEVICE_OPEN_V5:
		case ADM_CMD_DEVICE_OPEN_V8:
		case ADM_CMD_DEVICE_CLOSE_V5:
		case ADM_CMD_SET_PP_PARAMS_V5:
			/* dagu: wake SET_PP_PARAMS / OPEN_V8 */
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: CMDRSP OPEN_V8",
    """	case ADM_CMDRSP_DEVICE_OPEN_V5: {
""",
    """	case ADM_CMDRSP_DEVICE_OPEN_V5:
	case ADM_CMDRSP_DEVICE_OPEN_V8: {
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu fluence topo 0x%x eid2 failed",
    """		/* dagu: open Fluence COPP on capture */
		if (session->path_type == ADM_PATH_LIVE_REC && dagu_fluence_aec_ns &&
		    session->port_id == TX_CODEC_DMA_TX_3) {
			topology = VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY;
			ec_ref = TERTIARY_TDM_RX_0;
		}
		copp = q6adm_open(routing_data->dev, session->port_id,
				  session->path_type, session->sample_rate,
				  session->channels, topology, perf_mode,
				  session->bits_per_sample, 0, 0, ec_ref);
		if (IS_ERR_OR_NULL(copp) && topology != NULL_COPP_TOPOLOGY) {
			dev_warn(routing_data->dev,
				 "dagu fluence topo 0x%x failed, NULL_COPP\\n",
				 topology);
			topology = NULL_COPP_TOPOLOGY;
			copp = q6adm_open(routing_data->dev, session->port_id,
					  session->path_type, session->sample_rate,
					  session->channels, topology, perf_mode,
					  session->bits_per_sample, 0, 0, 0);
		}
""",
    """		int ch = session->channels;
		int bw = session->bits_per_sample;
		int rate = session->sample_rate;
		static const u32 fluence_topos[] = {
			VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY,
			VPM_TX_SM_ECNS_COPP_TOPOLOGY,
		};
		int i;

		/* dagu: open Fluence COPP on capture */
		if (session->path_type == ADM_PATH_LIVE_REC && dagu_fluence_aec_ns &&
		    session->port_id == TX_CODEC_DMA_TX_3) {
			ec_ref = TERTIARY_TDM_RX_0;
			if (ch != 1)
				ch = 1;
			for (i = 0; i < ARRAY_SIZE(fluence_topos); i++) {
				topology = fluence_topos[i];
				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, rate, ch,
						  topology, perf_mode, bw, 0, 0,
						  ec_ref);
				if (!IS_ERR_OR_NULL(copp))
					break;
				dev_warn(routing_data->dev,
					 "dagu fluence topo 0x%x eid2 failed, NS-only\\n",
					 topology);
				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, rate, ch,
						  topology, perf_mode, bw, 0, 0, 0);
				if (!IS_ERR_OR_NULL(copp))
					break;
				dev_warn(routing_data->dev,
					 "dagu fluence topo 0x%x failed\\n",
					 topology);
			}
			if (IS_ERR_OR_NULL(copp)) {
				dev_warn(routing_data->dev,
					 "dagu fluence topo 0x%x failed, NULL_COPP\\n",
					 topology);
				topology = NULL_COPP_TOPOLOGY;
				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, session->sample_rate,
						  session->channels, topology, perf_mode,
						  session->bits_per_sample, 0, 0, 0);
			}
		} else {
			copp = q6adm_open(routing_data->dev, session->port_id,
					  session->path_type, session->sample_rate,
					  session->channels, topology, perf_mode,
					  session->bits_per_sample, 0, 0, 0);
		}
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu adm open_v8",
    """static int q6adm_device_open(struct q6adm *adm, struct q6copp *copp,
			     int port_id, int path, int topology,
			     int channel_mode, int bit_width, int rate,
			     int ec_ref_idx)
{
	struct q6adm_cmd_device_open_v5 *open;
	int afe_port = q6afe_get_port_id(port_id);
	struct apr_pkt *pkt;
	int ret, pkt_size = APR_HDR_SIZE + sizeof(*open);

	void *p __free(kfree) = kzalloc(pkt_size, GFP_KERNEL);
	if (!p)
		return -ENOMEM;

	pkt = p;
	open = p + APR_HDR_SIZE;
	pkt->hdr.hdr_field = APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD,
					   APR_HDR_LEN(APR_HDR_SIZE),
					   APR_PKT_VER);
	pkt->hdr.pkt_size = pkt_size;
	pkt->hdr.src_port = afe_port;
	pkt->hdr.dest_port = afe_port;
	pkt->hdr.token = port_id << 16 | copp->copp_idx;
	pkt->hdr.opcode = ADM_CMD_DEVICE_OPEN_V5;
	open->flags = ADM_LEGACY_DEVICE_SESSION;
	open->mode_of_operation = path;
	open->endpoint_id_1 = afe_port;
	/* dagu: fill endpoint_id_2 for Fluence */
	if (ec_ref_idx > 0) {
		int ec = q6afe_get_port_id(ec_ref_idx);

		open->endpoint_id_2 = (ec > 0) ? ec : AFE_PORT_INVALID;
	} else {
		open->endpoint_id_2 = AFE_PORT_INVALID;
	}
	open->topology_id = topology;
	open->dev_num_channel = channel_mode & 0x00FF;
	open->bit_width = bit_width;
	open->sample_rate = rate;

	ret = q6dsp_map_channels(&open->dev_channel_mapping[0],
				 channel_mode);
	if (ret)
		return ret;

	return q6adm_apr_send_copp_pkt(adm, copp, pkt, ADM_CMDRSP_DEVICE_OPEN_V5);
}
""",
    """static bool q6adm_is_fluence_topo(int topology)
{
	return topology == VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY ||
	       topology == VPM_TX_SM_ECNS_COPP_TOPOLOGY;
}

static int q6adm_ep_bytes(int channels)
{
	return 8 + round_up(channels, 4);
}

static int q6adm_fill_ep(struct q6adm_device_endpoint_payload *ep,
			 int channels, int bit_width, int rate)
{
	u8 map[PCM_MAX_NUM_CHANNEL];
	int ret;

	memset(ep, 0, sizeof(*ep));
	ep->dev_num_channel = channels & 0x00FF;
	ep->bit_width = bit_width;
	ep->sample_rate = rate;
	ret = q6dsp_map_channels(map, channels);
	if (ret)
		return ret;
	memcpy(ep->dev_channel_mapping, map, sizeof(map));
	return 0;
}

static int q6adm_device_open_v8(struct q6adm *adm, struct q6copp *copp,
				int port_id, int path, int topology,
				int channel_mode, int bit_width, int rate,
				int ec_ref_idx)
{
	struct q6adm_cmd_device_open_v8 open = { };
	struct q6adm_device_endpoint_payload ep1, ep2;
	int afe_port = q6afe_get_port_id(port_id);
	int ep1_sz, ep2_sz = 0, pkt_size, ret;
	struct apr_pkt *pkt;
	u8 *payload;
	void *p __free(kfree) = NULL;

	ret = q6adm_fill_ep(&ep1, channel_mode, bit_width, rate);
	if (ret)
		return ret;
	ep1_sz = q6adm_ep_bytes(channel_mode);

	open.flags = ADM_LEGACY_DEVICE_SESSION;
	open.mode_of_operation = path;
	open.topology_id = topology;
	open.endpoint_id_1 = afe_port;
	open.endpoint_id_2 = AFE_PORT_INVALID;
	open.endpoint_id_3 = AFE_PORT_INVALID;

	if (ec_ref_idx > 0) {
		int ec = q6afe_get_port_id(ec_ref_idx);

		if (ec > 0) {
			open.endpoint_id_2 = ec;
			ret = q6adm_fill_ep(&ep2, 4, 24, 48000);
			if (ret)
				return ret;
			ep2_sz = q6adm_ep_bytes(4);
		}
	}

	pkt_size = APR_HDR_SIZE + sizeof(open) + ep1_sz + ep2_sz;
	p = kzalloc(pkt_size, GFP_KERNEL);
	if (!p)
		return -ENOMEM;

	pkt = p;
	payload = p + APR_HDR_SIZE;
	pkt->hdr.hdr_field = APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD,
					   APR_HDR_LEN(APR_HDR_SIZE),
					   APR_PKT_VER);
	pkt->hdr.pkt_size = pkt_size;
	pkt->hdr.src_port = afe_port;
	pkt->hdr.dest_port = afe_port;
	pkt->hdr.token = port_id << 16 | copp->copp_idx;
	pkt->hdr.opcode = ADM_CMD_DEVICE_OPEN_V8;
	memcpy(payload, &open, sizeof(open));
	memcpy(payload + sizeof(open), &ep1, ep1_sz);
	if (ep2_sz)
		memcpy(payload + sizeof(open) + ep1_sz, &ep2, ep2_sz);

	dev_info(adm->dev,
		 "dagu adm open_v8 topo=0x%x ep1=0x%x %dch/%d/%d ep2=0x%x %dch/%d/%d\\n",
		 topology, afe_port, channel_mode, bit_width, rate,
		 open.endpoint_id_2,
		 ep2_sz ? ep2.dev_num_channel : 0,
		 ep2_sz ? ep2.bit_width : 0,
		 ep2_sz ? ep2.sample_rate : 0);

	return q6adm_apr_send_copp_pkt(adm, copp, pkt, ADM_CMDRSP_DEVICE_OPEN_V8);
}

static int q6adm_device_open(struct q6adm *adm, struct q6copp *copp,
			     int port_id, int path, int topology,
			     int channel_mode, int bit_width, int rate,
			     int ec_ref_idx)
{
	struct q6adm_cmd_device_open_v5 *open;
	int afe_port = q6afe_get_port_id(port_id);
	struct apr_pkt *pkt;
	int ret, pkt_size = APR_HDR_SIZE + sizeof(*open);
	void *p __free(kfree) = NULL;

	if (q6adm_is_fluence_topo(topology))
		return q6adm_device_open_v8(adm, copp, port_id, path, topology,
					    channel_mode, bit_width, rate,
					    ec_ref_idx);
	/* dagu: fill endpoint_id_2 for Fluence — V8 path above; V5 keeps 0xFFFF */

	p = kzalloc(pkt_size, GFP_KERNEL);
	if (!p)
		return -ENOMEM;

	pkt = p;
	open = p + APR_HDR_SIZE;
	pkt->hdr.hdr_field = APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD,
					   APR_HDR_LEN(APR_HDR_SIZE),
					   APR_PKT_VER);
	pkt->hdr.pkt_size = pkt_size;
	pkt->hdr.src_port = afe_port;
	pkt->hdr.dest_port = afe_port;
	pkt->hdr.token = port_id << 16 | copp->copp_idx;
	pkt->hdr.opcode = ADM_CMD_DEVICE_OPEN_V5;
	open->flags = ADM_LEGACY_DEVICE_SESSION;
	open->mode_of_operation = path;
	open->endpoint_id_1 = afe_port;
	open->endpoint_id_2 = AFE_PORT_INVALID;
	open->topology_id = topology;
	open->dev_num_channel = channel_mode & 0x00FF;
	open->bit_width = bit_width;
	open->sample_rate = rate;

	ret = q6dsp_map_channels(&open->dev_channel_mapping[0],
				 channel_mode);
	if (ret)
		return ret;

	return q6adm_apr_send_copp_pkt(adm, copp, pkt, ADM_CMDRSP_DEVICE_OPEN_V5);
}
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "q6adm_is_fluence_topo(topology)",
    """	if (topology == VPM_TX_SM_ECNS_V2_COPP_TOPOLOGY) {
""",
    """	if (q6adm_is_fluence_topo(topology)) {
""",
)

# --- follow-up: SM ECNS 1ch S16 echo + Android 0x10EAF 0x01/0x02 ---
patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "Android audio_platform_info",
    """static int q6adm_set_fluence_effect(struct q6adm *adm, struct q6copp *copp,
				    int port_id)
{
	struct {
		struct apr_hdr hdr;
		u32 payload_addr_lsw;
		u32 payload_addr_msw;
		u32 mem_map_handle;
		u32 payload_size;
		u32 module_id;
		u32 param_id;
		u16 param_size;
		u16 reserved;
		u32 value;
	} __packed pkt;
	int afe_port = q6afe_get_port_id(port_id);

	memset(&pkt, 0, sizeof(pkt));
	pkt.hdr.hdr_field = APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD,
					  APR_HDR_LEN(APR_HDR_SIZE),
					  APR_PKT_VER);
	pkt.hdr.pkt_size = sizeof(pkt);
	pkt.hdr.src_port = afe_port;
	pkt.hdr.dest_port = copp->id;
	pkt.hdr.token = port_id << 16 | copp->copp_idx;
	pkt.hdr.opcode = ADM_CMD_SET_PP_PARAMS_V5;
	pkt.payload_size = 16;
	pkt.module_id = AUDPROC_MODULE_ID_FLUENCE_SMECNS;
	pkt.param_id = FLUENCE_CMN_GLOBAL_EFFECT_PARAM_ID;
	pkt.param_size = sizeof(pkt.value);
	pkt.value = FLUENCE_EFFECT_AEC | FLUENCE_EFFECT_NS;

	return q6adm_apr_send_copp_pkt(adm, copp, (struct apr_pkt *)&pkt, 0);
}
""",
    """static int q6adm_set_fluence_effect(struct q6adm *adm, struct q6copp *copp,
				    int port_id, u32 effect)
{
	struct {
		struct apr_hdr hdr;
		u32 payload_addr_lsw;
		u32 payload_addr_msw;
		u32 mem_map_handle;
		u32 payload_size;
		u32 module_id;
		u32 param_id;
		u16 param_size;
		u16 reserved;
		u32 value;
	} __packed pkt;
	int afe_port = q6afe_get_port_id(port_id);
	int ret;

	memset(&pkt, 0, sizeof(pkt));
	pkt.hdr.hdr_field = APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD,
					  APR_HDR_LEN(APR_HDR_SIZE),
					  APR_PKT_VER);
	pkt.hdr.pkt_size = sizeof(pkt);
	pkt.hdr.src_port = afe_port;
	pkt.hdr.dest_port = copp->id;
	pkt.hdr.token = port_id << 16 | copp->copp_idx;
	pkt.hdr.opcode = ADM_CMD_SET_PP_PARAMS_V5;
	pkt.payload_size = 16;
	pkt.module_id = AUDPROC_MODULE_ID_FLUENCE_SMECNS;
	pkt.param_id = FLUENCE_CMN_GLOBAL_EFFECT_PARAM_ID;
	pkt.param_size = sizeof(pkt.value);
	pkt.value = effect;

	ret = q6adm_apr_send_copp_pkt(adm, copp, (struct apr_pkt *)&pkt, 0);
	if (ret > 0)
		return 0;
	return ret;
}
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "SM ECNS far-end is 1ch",
    """			open.endpoint_id_2 = ec;
			ret = q6adm_fill_ep(&ep2, 4, 24, 48000);
			if (ret)
				return ret;
			ep2_sz = q6adm_ep_bytes(4);
""",
    """			open.endpoint_id_2 = ec;
			ret = q6adm_fill_ep(&ep2, 1, 16, 48000);
			if (ret)
				return ret;
			ep2_sz = q6adm_ep_bytes(1);
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: Fluence PP AEC iff echo",
    """	if (q6adm_is_fluence_topo(topology)) {
		ret = q6adm_set_fluence_effect(adm, copp, port_id);
		dev_info(dev, "dagu fluence topo=0x%x ec_idx=%d pp=%d copp=%d\\n",
			 topology, ec_ref_idx, ret, copp->id);
		if (ret)
			dev_warn(dev, "dagu fluence PP params failed (%d); COPP still open\\n",
				 ret);
	}
""",
    """	if (q6adm_is_fluence_topo(topology)) {
		u32 effect = ec_ref_idx > 0 ? FLUENCE_EFFECT_AEC :
					      FLUENCE_EFFECT_NS;

		ret = q6adm_set_fluence_effect(adm, copp, port_id, effect);
		dev_info(dev, "dagu fluence topo=0x%x ec_idx=%d effect=0x%x pp=%d copp=%d\\n",
			 topology, ec_ref_idx, effect, ret, copp->id);
		if (ret < 0)
			dev_warn(dev, "dagu fluence PP params failed (%d); COPP still open\\n",
				 ret);
	}
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: Fluence AEC echo matches TDM 2ch",
    """			ec_ref = TERTIARY_TDM_RX_0;
			if (ch != 1)
				ch = 1;
			for (i = 0; i < ARRAY_SIZE(fluence_topos); i++) {
				topology = fluence_topos[i];
				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, rate, ch,
						  topology, perf_mode, bw, 0, 0,
						  ec_ref);
""",
    """			ch = 1;
			bw = 16;
			rate = 48000;
			ec_ref = TERTIARY_TDM_RX_0;
			for (i = 0; i < ARRAY_SIZE(fluence_topos); i++) {
				topology = fluence_topos[i];
				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, rate, ch,
						  topology, perf_mode, bw, 0, 0,
						  ec_ref);
				if (!IS_ERR_OR_NULL(copp))
					break;
				dev_warn(routing_data->dev,
					 "dagu fluence topo 0x%x 16-bit AEC failed, 24-bit\\n",
					 topology);
				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, rate, ch,
						  topology, perf_mode, 24, 0, 0,
						  ec_ref);
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: NS-only first no eid2",
    """			ch = 1;
			bw = 16;
			rate = 48000;
			ec_ref = TERTIARY_TDM_RX_0;
""",
    """			ch = 1;
			bw = 16;
			rate = 48000;
			ec_ref = 0;
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: NS-only uses OPEN_V5",
    """	if (q6adm_is_fluence_topo(topology))
		return q6adm_device_open_v8(adm, copp, port_id, path, topology,
					    channel_mode, bit_width, rate,
					    ec_ref_idx);
""",
    """	if (q6adm_is_fluence_topo(topology) && ec_ref_idx > 0)
		return q6adm_device_open_v8(adm, copp, port_id, path, topology,
					    channel_mode, bit_width, rate,
					    ec_ref_idx);
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu: AEC echo TDM 2ch S24",
    """			ch = 1;
			bw = session->bits_per_sample;
			if (bw < 16)
				bw = 16;
			rate = session->sample_rate ?: 48000;
			ec_ref = 0;
""",
    """			ch = 1;
			bw = 16;
			rate = session->sample_rate ?: 48000;
			ec_ref = TERTIARY_TDM_RX_0;
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: AEC echo matches live TDM 2ch S24",
    """			ret = q6adm_fill_ep(&ep2, 1, 16, 48000);
			if (ret)
				return ret;
			ep2_sz = q6adm_ep_bytes(1);
""",
    """			ret = q6adm_fill_ep(&ep2, 2, 24, 48000);
			if (ret)
				return ret;
			ep2_sz = q6adm_ep_bytes(2);
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6routing.c",
    "dagu fluence 24-bit retry keeps echo",
    """				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, rate, ch,
						  topology, perf_mode, 24, 0, 0, 0);
""",
    """				copp = q6adm_open(routing_data->dev, session->port_id,
						  session->path_type, rate, ch,
						  topology, perf_mode, 24, 0, 0,
						  ec_ref);
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: skip SET_PP until PCM",
    """	if (q6adm_is_fluence_topo(topology)) {
		u32 effect = ec_ref_idx > 0 ? FLUENCE_EFFECT_AEC :
					      FLUENCE_EFFECT_NS;

		ret = q6adm_set_fluence_effect(adm, copp, port_id, effect);
		dev_info(dev, "dagu fluence topo=0x%x ec_idx=%d effect=0x%x pp=%d copp=%d\\n",
			 topology, ec_ref_idx, effect, ret, copp->id);
		if (ret < 0)
			dev_warn(dev, "dagu fluence PP params failed (%d); COPP still open\\n",
				 ret);
	}
""",
    """	if (q6adm_is_fluence_topo(topology)) {
		dev_info(dev, "dagu fluence topo=0x%x ec_idx=%d effect=skip pp=na copp=%d\\n",
			 topology, ec_ref_idx, copp->id);
	}
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "AUDPROC_PARAM_ID_ENABLE",
    """#define FLUENCE_EFFECT_NS			BIT(1)
#define AFE_PORT_INVALID		0xFFFF
""",
    """#define FLUENCE_EFFECT_NS			BIT(1)
#define AUDPROC_PARAM_ID_ENABLE			0x00010E00
#define AFE_PORT_INVALID		0xFFFF
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "CAF adm_param_enable: Fluence SM sits disabled",
    """	ret = q6adm_apr_send_copp_pkt(adm, copp, (struct apr_pkt *)&pkt, 0);
	if (ret > 0)
		return 0;
	return ret;
}

static bool q6adm_is_fluence_topo(int topology)
""",
    """	ret = q6adm_apr_send_copp_pkt(adm, copp, (struct apr_pkt *)&pkt, 0);
	if (ret > 0)
		return 0;
	return ret;
}

/* CAF adm_param_enable: Fluence SM sits disabled until 0x10E00=1. */
static int q6adm_set_fluence_enable(struct q6adm *adm, struct q6copp *copp,
				    int port_id, u32 enable)
{
	struct {
		struct apr_hdr hdr;
		u32 payload_addr_lsw;
		u32 payload_addr_msw;
		u32 mem_map_handle;
		u32 payload_size;
		u32 module_id;
		u32 param_id;
		u16 param_size;
		u16 reserved;
		u32 value;
	} __packed pkt;
	int afe_port = q6afe_get_port_id(port_id);
	int ret;

	memset(&pkt, 0, sizeof(pkt));
	pkt.hdr.hdr_field = APR_HDR_FIELD(APR_MSG_TYPE_SEQ_CMD,
					  APR_HDR_LEN(APR_HDR_SIZE),
					  APR_PKT_VER);
	pkt.hdr.pkt_size = sizeof(pkt);
	pkt.hdr.src_port = afe_port;
	pkt.hdr.dest_port = copp->id;
	pkt.hdr.token = port_id << 16 | copp->copp_idx;
	pkt.hdr.opcode = ADM_CMD_SET_PP_PARAMS_V5;
	pkt.payload_size = 16;
	pkt.module_id = AUDPROC_MODULE_ID_FLUENCE_SMECNS;
	pkt.param_id = AUDPROC_PARAM_ID_ENABLE;
	pkt.param_size = sizeof(pkt.value);
	pkt.value = enable;

	ret = q6adm_apr_send_copp_pkt(adm, copp, (struct apr_pkt *)&pkt, 0);
	if (ret > 0)
		return 0;
	return ret;
}

static bool q6adm_is_fluence_topo(int topology)
""",
)

patch(
    "sound/soc/qcom/qdsp6/q6adm.c",
    "dagu: Fluence ENABLE then 0x10EAF",
    """	if (q6adm_is_fluence_topo(topology)) {
		dev_info(dev, "dagu fluence topo=0x%x ec_idx=%d effect=skip pp=na copp=%d\\n",
			 topology, ec_ref_idx, copp->id);
	}
""",
    """	if (q6adm_is_fluence_topo(topology)) {
		u32 effect = ec_ref_idx > 0 ? FLUENCE_EFFECT_AEC :
					      FLUENCE_EFFECT_NS;
		int en;

		en = q6adm_set_fluence_enable(adm, copp, port_id, 1);
		ret = q6adm_set_fluence_effect(adm, copp, port_id, effect);
		dev_info(dev, "dagu fluence topo=0x%x ec_idx=%d effect=0x%x enable=%d pp=%d copp=%d\\n",
			 topology, ec_ref_idx, effect, en, ret, copp->id);
		if (en < 0 || ret < 0)
			dev_warn(dev, "dagu fluence PP params failed enable=%d pp=%d; COPP still open\\n",
				 en, ret);
	}
""",
)

print("dagu-overlay-adsp-voice: ok")


