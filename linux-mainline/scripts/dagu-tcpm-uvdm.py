#!/usr/bin/env python3
"""Teach TCPM the Xiaomi unstructured vendor messages and the safe PPS pick.

Re-applied every build. linux/ is a checkout; this is the copy that survives.
"""
import sys
from pathlib import Path

tcpm = Path(sys.argv[1]) / "drivers/usb/typec/tcpm/tcpm.c"
text = tcpm.read_text()


def apply_incremental(text):
    """Patches that must land even when the first UVDM insert already ran."""
    cap_old = '\t\ttcpm_log(port, " PDO %d: type %d, %s",\n\t\t\t i, type, msg);\n'
    cap_new = (
        cap_old
        + "\t\tif (port->dagu_fixed_mv_cap)\n"
        + '\t\t\tdev_info(port->dev, "dagu src cap %d: %s\\n", i, msg);\n'
    )
    if "dagu src cap" not in text:
        if cap_old not in text:
            raise SystemExit("source-cap log anchor missing")
        text = text.replace(cap_old, cap_new, 1)
    if "tcpm_dagu_pps_limit" not in text:
        anchor = "static int tcpm_dagu_set_fixed_cap(struct tcpm_port *port, unsigned int mv)\n"
        extra = '''int tcpm_dagu_pps_limit(struct power_supply *psy, int *max_mv, int *max_ma)
{
	struct tcpm_port *port = power_supply_get_drvdata(psy);
	unsigned int i, best_ma = 0, best_mv = 0;

	if (!port || !max_mv || !max_ma)
		return -EINVAL;
	mutex_lock(&port->lock);
	for (i = 1; i < port->nr_source_caps; i++) {
		u32 pdo = port->source_caps[i];
		unsigned int mv, ma;

		if (pdo_type(pdo) != PDO_TYPE_APDO ||
		    pdo_apdo_type(pdo) != APDO_TYPE_PPS)
			continue;
		mv = pdo_pps_apdo_max_voltage(pdo);
		if (mv > 11000)
			continue;
		ma = pdo_pps_apdo_max_current(pdo);
		if (ma > best_ma) {
			best_ma = ma;
			best_mv = mv;
		}
	}
	mutex_unlock(&port->lock);
	*max_mv = best_mv;
	*max_ma = best_ma;
	return 0;
}
EXPORT_SYMBOL_GPL(tcpm_dagu_pps_limit);

'''
        proto = "int tcpm_dagu_get_source_cap(struct power_supply *psy);\n"
        if anchor not in text or proto not in text:
            raise SystemExit("pps limit anchor missing")
        text = text.replace(proto, proto + "int tcpm_dagu_pps_limit(struct power_supply *psy, int *max_mv, int *max_ma);\n", 1)
        text = text.replace(anchor, extra + anchor, 1)
    return text


if "dagu_uvdm_waiting" in text:
    tcpm.write_text(apply_incremental(text))
    raise SystemExit(0)


def sub(old, new):
    global text
    if old not in text:
        raise SystemExit("anchor missing:\n" + old[:180])
    text = text.replace(old, new, 1)


sub(
    "\tunsigned int dagu_fixed_mv_cap;\n",
    """\tunsigned int dagu_fixed_mv_cap;

	/* dagu: Xiaomi unstructured VDM reply, SVID 0x2717. */
	u32 dagu_uvdm_reply[PD_MAX_PAYLOAD];
	int dagu_uvdm_reply_cnt;
	bool dagu_uvdm_waiting;
	struct completion dagu_uvdm_done;
""",
)

sub(
    "static void tcpm_handle_vdm_request(struct tcpm_port *port,\n",
    """static void dagu_uvdm_complete(struct tcpm_port *port)
{
	if (!port->dagu_uvdm_waiting)
		return;
	port->dagu_uvdm_waiting = false;
	complete(&port->dagu_uvdm_done);
}

static void tcpm_handle_vdm_request(struct tcpm_port *port,
""",
)

sub(
    "\tif (PD_VDO_SVDM(p[0]) && (adev || tcpm_vdm_ams(port) || port->nr_snk_vdo)) {\n",
    """\t/*
	 * dagu: Xiaomi UVDM is unstructured. A Not_Supported here makes
	 * the charger drop the digest and the port hard-resets.
	 */
	if (cnt > 0 && !PD_VDO_SVDM(p[0]) && PD_VDO_VID(p[0]) == 0x2717 &&
	    port->dagu_uvdm_waiting) {
		int n = cnt;

		if (n > PD_MAX_PAYLOAD)
			n = PD_MAX_PAYLOAD;
		memcpy(port->dagu_uvdm_reply, p, n * sizeof(u32));
		port->dagu_uvdm_reply_cnt = n;
		port->vdm_state = VDM_STATE_DONE;
		port->vdm_sm_running = false;
		hrtimer_cancel(&port->vdm_state_machine_timer);
		if (port->ams == UNSTRUCTURED_VDMS)
			tcpm_ams_finish(port);
		dagu_uvdm_complete(port);
		return;
	}

	if (PD_VDO_SVDM(p[0]) && (adev || tcpm_vdm_ams(port) || port->nr_snk_vdo)) {
""",
)

sub(
    """\tif (port->vdm_state < VDM_STATE_READY)
\t\tport->vdm_sm_running = false;
""",
    """\tif (port->vdm_state < VDM_STATE_READY) {
\t\tport->vdm_sm_running = false;
\t\tdagu_uvdm_complete(port);
\t}
""",
)

sub(
    """\tinit_completion(&port->tx_complete);
\tinit_completion(&port->swap_complete);
\tinit_completion(&port->pps_complete);
""",
    """\tinit_completion(&port->tx_complete);
\tinit_completion(&port->swap_complete);
\tinit_completion(&port->pps_complete);
\tinit_completion(&port->dagu_uvdm_done);
""",
)

sub(
    """\tunsigned int i, src_ma, max_temp_mw = 0, max_op_ma, op_mw;
\tunsigned int src_pdo = 0;
""",
    """\tunsigned int i, src_ma, max_temp_mw = 0, max_op_ma, op_mw;
\tunsigned int src_pdo = 0, best_ma = 0;
""",
)

sub(
    """\t\t\tif (port->pps_data.req_out_volt > pdo_pps_apdo_max_voltage(pdo) ||
\t\t\t    port->pps_data.req_out_volt < pdo_pps_apdo_min_voltage(pdo))
\t\t\t\tcontinue;
""",
    """\t\t\t/*
\t\t\t * dagu: pump over-voltage alarm is 11 V. Skip 15 V / 20 V.
\t\t\t * Pick the highest advertised current, not the power at the
\t\t\t * old request, or a 6 A object stays hidden behind 5 A.
\t\t\t */
\t\t\tif (port->dagu_fixed_mv_cap) {
\t\t\t\tunsigned int max_mv = pdo_pps_apdo_max_voltage(pdo);

\t\t\t\tif (max_mv > 11000)
\t\t\t\t\tcontinue;
\t\t\t\tif (port->pps_data.req_out_volt > max_mv ||
\t\t\t\t    port->pps_data.req_out_volt < pdo_pps_apdo_min_voltage(pdo))
\t\t\t\t\tcontinue;
\t\t\t\tsrc_ma = pdo_pps_apdo_max_current(pdo);
\t\t\t\tif (!src_pdo || src_ma > best_ma) {
\t\t\t\t\tsrc_pdo = i;
\t\t\t\t\tbest_ma = src_ma;
\t\t\t\t}
\t\t\t\tcontinue;
\t\t\t}

\t\t\tif (port->pps_data.req_out_volt > pdo_pps_apdo_max_voltage(pdo) ||
\t\t\t    port->pps_data.req_out_volt < pdo_pps_apdo_min_voltage(pdo))
\t\t\t\tcontinue;
""",
)

helper = r'''int tcpm_dagu_uvdm(struct power_supply *psy, u32 header, const u32 *data,
		   int cnt, u32 *reply, int *reply_cnt);
int tcpm_dagu_adapter_pid(struct power_supply *psy, u32 *pid);
int tcpm_dagu_get_source_cap(struct power_supply *psy);

int tcpm_dagu_uvdm(struct power_supply *psy, u32 header, const u32 *data,
		   int cnt, u32 *reply, int *reply_cnt)
{
	struct tcpm_port *port = power_supply_get_drvdata(psy);
	u32 dummy = 0;
	int ret = 0;
	unsigned long left;

	if (!port)
		return -ENODEV;
	if (cnt < 0 || cnt > 6)
		return -EINVAL;
	if (!data)
		data = &dummy;

	mutex_lock(&port->swap_lock);
	mutex_lock(&port->lock);
	if (port->state != SNK_READY || port->vdm_state > VDM_STATE_DONE) {
		ret = -EAGAIN;
		goto out;
	}
	ret = tcpm_ams_start(port, UNSTRUCTURED_VDMS);
	if (ret)
		goto out;

	memset(port->dagu_uvdm_reply, 0, sizeof(port->dagu_uvdm_reply));
	port->dagu_uvdm_reply_cnt = 0;
	reinit_completion(&port->dagu_uvdm_done);
	port->dagu_uvdm_waiting = true;
	tcpm_log(port, "dagu uvdm %08x n=%d", header, cnt);
	tcpm_queue_vdm(port, header, data, cnt, TCPC_TX_SOP);
	mutex_unlock(&port->lock);

	left = wait_for_completion_timeout(&port->dagu_uvdm_done,
					   msecs_to_jiffies(1000));

	mutex_lock(&port->lock);
	hrtimer_cancel(&port->vdm_state_machine_timer);
	if (!left) {
		port->dagu_uvdm_waiting = false;
		if (port->vdm_state > VDM_STATE_DONE)
			port->vdm_state = VDM_STATE_DONE;
		port->vdm_sm_running = false;
		if (port->ams == UNSTRUCTURED_VDMS)
			tcpm_ams_finish(port);
		ret = -ETIMEDOUT;
		goto out;
	}
	if (port->dagu_uvdm_reply_cnt <= 0) {
		ret = -EIO;
		goto out;
	}
	if (reply && reply_cnt) {
		int n = port->dagu_uvdm_reply_cnt;

		if (n > PD_MAX_PAYLOAD)
			n = PD_MAX_PAYLOAD;
		memcpy(reply, port->dagu_uvdm_reply, n * sizeof(u32));
		*reply_cnt = n;
	}
	ret = 0;
out:
	mutex_unlock(&port->lock);
	mutex_unlock(&port->swap_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(tcpm_dagu_uvdm);

int tcpm_dagu_adapter_pid(struct power_supply *psy, u32 *pid)
{
	struct tcpm_port *port = power_supply_get_drvdata(psy);

	if (!port || !pid)
		return -EINVAL;
	mutex_lock(&port->lock);
	*pid = port->partner_ident.product & 0xffff;
	mutex_unlock(&port->lock);
	return 0;
}
EXPORT_SYMBOL_GPL(tcpm_dagu_adapter_pid);

int tcpm_dagu_get_source_cap(struct power_supply *psy)
{
	struct tcpm_port *port = power_supply_get_drvdata(psy);
	int ret;

	if (!port)
		return -ENODEV;
	mutex_lock(&port->swap_lock);
	mutex_lock(&port->lock);
	if (port->state != SNK_READY || port->vdm_sm_running) {
		ret = -EAGAIN;
		goto out;
	}
	port->ams = GET_SOURCE_CAPABILITIES;
	ret = tcpm_pd_send_control(port, PD_CTRL_GET_SOURCE_CAP, TCPC_TX_SOP);
	if (ret)
		port->ams = NONE_AMS;
	else
		tcpm_log(port, "dagu Get_Source_Cap");
out:
	mutex_unlock(&port->lock);
	mutex_unlock(&port->swap_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(tcpm_dagu_get_source_cap);

'''

sub(
    "static int tcpm_dagu_set_fixed_cap(struct tcpm_port *port, unsigned int mv)\n",
    helper + "static int tcpm_dagu_set_fixed_cap(struct tcpm_port *port, unsigned int mv)\n",
)

tcpm.write_text(apply_incremental(text))
print("patched", tcpm)
