#!/usr/bin/env python3
"""Ask for a Wi-Fi password before NetworkManager drops the current network.

gnome-control-center 50 activates a secured access point immediately.
NetworkManager then disconnects the associated network and asks the
secret agent. This image has no secret service, so the agent returns
at once, the password dialog never appears, and the current network is
already gone. Show the password dialog first. Only activate after the
password is in the connection.
"""
import sys
from pathlib import Path

MARKER = "dagu: ask for the Wi-Fi password before activating"

HEADER_ANCHOR = "void cc_network_panel_connect_to_8021x_network"
HEADER_INSERT = """void cc_network_panel_connect_to_wifi_ap (GtkWidget      *toplevel,
                                          NMClient       *client,
                                          NMDevice       *device,
                                          NMAccessPoint  *ap);

"""

HELPERS = r'''
typedef struct {
        NMClient *client;
        NMDevice *device;
        char *ap_path;
        NMRemoteConnection *remote;
} WifiSecretCommit;

static void
wifi_secret_commit_free (WifiSecretCommit *commit)
{
        g_clear_object (&commit->client);
        g_clear_object (&commit->device);
        g_clear_object (&commit->remote);
        g_free (commit->ap_path);
        g_free (commit);
}

static void
wifi_secret_commit_cb (GObject      *source_object,
                       GAsyncResult *res,
                       gpointer      user_data)
{
        WifiSecretCommit *commit = user_data;
        g_autoptr(GError) error = NULL;

        if (!nm_remote_connection_commit_changes_finish (NM_REMOTE_CONNECTION (source_object),
                                                         res, &error)) {
                g_warning ("Failed to save Wi-Fi password: %s", error->message);
                wifi_secret_commit_free (commit);
                return;
        }

        nm_client_activate_connection_async (commit->client,
                                             NM_CONNECTION (commit->remote),
                                             commit->device,
                                             commit->ap_path,
                                             NULL,
                                             activate_existing_cb,
                                             NULL);
        wifi_secret_commit_free (commit);
}

/* Store the passphrase in NetworkManager's connection file. Agent-owned
 * secrets go to the secret service, which is not installed here, so the
 * password would be thrown away after this attempt.
 */
static void
wifi_store_psk_locally (NMConnection *connection)
{
        NMSettingWirelessSecurity *sec;
        const char *psk;

        sec = nm_connection_get_setting_wireless_security (connection);
        if (sec == NULL)
                return;
        psk = nm_setting_wireless_security_get_psk (sec);
        if (psk == NULL || psk[0] == '\0')
                return;
        nm_setting_set_secret_flags (NM_SETTING (sec),
                                     NM_SETTING_WIRELESS_SECURITY_PSK,
                                     NM_SETTING_SECRET_FLAG_NONE,
                                     NULL);
}

'''

FUZZY_OLD = """\tif (fuzzy_match) {
\t\tnm_client_activate_connection_async (closure->client,
\t\t                                     fuzzy_match,
\t\t                                     device,
\t\t                                     ap ? nm_object_get_path (NM_OBJECT (ap)) : NULL,
\t\t                                     NULL,
\t\t                                     activate_existing_cb,
\t\t                                     NULL);
\t} else {"""

FUZZY_NEW = """\t/* dagu: ask for the Wi-Fi password before activating.
\t * A saved profile from a previous attempt has no passphrase. Activating
\t * that profile drops the current network and then finds no secret agent.
\t */
\twifi_store_psk_locally (connection);
\tif (fuzzy_match) {
\t\tNMSettingWirelessSecurity *sec;
\t\tconst char *psk = NULL;

\t\tsec = nm_connection_get_setting_wireless_security (connection);
\t\tif (sec != NULL)
\t\t\tpsk = nm_setting_wireless_security_get_psk (sec);
\t\tif (psk != NULL && psk[0] != '\\0' && NM_IS_REMOTE_CONNECTION (fuzzy_match)) {
\t\t\tNMSettingWirelessSecurity *saved;
\t\t\tWifiSecretCommit *commit;

\t\t\tsaved = nm_connection_get_setting_wireless_security (fuzzy_match);
\t\t\tif (saved == NULL) {
\t\t\t\tsaved = NM_SETTING_WIRELESS_SECURITY (nm_setting_wireless_security_new ());
\t\t\t\tnm_connection_add_setting (fuzzy_match, NM_SETTING (saved));
\t\t\t}
\t\t\tg_object_set (saved, NM_SETTING_WIRELESS_SECURITY_PSK, psk, NULL);
\t\t\tnm_setting_set_secret_flags (NM_SETTING (saved),
\t\t\t                             NM_SETTING_WIRELESS_SECURITY_PSK,
\t\t\t                             NM_SETTING_SECRET_FLAG_NONE,
\t\t\t                             NULL);
\t\t\tcommit = g_new0 (WifiSecretCommit, 1);
\t\t\tcommit->client = g_object_ref (closure->client);
\t\t\tcommit->device = g_object_ref (device);
\t\t\tcommit->remote = g_object_ref (NM_REMOTE_CONNECTION (fuzzy_match));
\t\t\tif (ap != NULL)
\t\t\t\tcommit->ap_path = g_strdup (nm_object_get_path (NM_OBJECT (ap)));
\t\t\tnm_remote_connection_commit_changes_async (NM_REMOTE_CONNECTION (fuzzy_match),
\t\t\t                                           TRUE,
\t\t\t                                           NULL,
\t\t\t                                           wifi_secret_commit_cb,
\t\t\t                                           commit);
\t\t} else {
\t\t\tnm_client_activate_connection_async (closure->client,
\t\t\t                                     fuzzy_match,
\t\t\t                                     device,
\t\t\t                                     ap ? nm_object_get_path (NM_OBJECT (ap)) : NULL,
\t\t\t                                     NULL,
\t\t\t                                     activate_existing_cb,
\t\t\t                                     NULL);
\t\t}
\t} else {"""

PUBLIC_ANCHOR = "void\ncc_network_panel_connect_to_hidden_network"
PUBLIC_INSERT = '''static void
dagu_wifi_fill_secret_entries (GtkWidget *widget, const char *psk)
{
        GtkWidget *child;

        if (GTK_IS_EDITABLE (widget) &&
            !GTK_IS_COMBO_BOX (widget) &&
            gtk_widget_get_visible (widget))
                gtk_editable_set_text (GTK_EDITABLE (widget), psk);
        for (child = gtk_widget_get_first_child (widget);
             child != NULL;
             child = gtk_widget_get_next_sibling (child))
                dagu_wifi_fill_secret_entries (child, psk);
}

static gboolean
dagu_wifi_do_ok (gpointer data)
{
        gtk_dialog_response (GTK_DIALOG (data), GTK_RESPONSE_OK);
        return G_SOURCE_REMOVE;
}

static gboolean
dagu_wifi_try_file_submit (gpointer data)
{
        GtkWidget *dialog = data;
        g_autofree char *psk = NULL;
        const char *path = "/run/user/1001/dagu-wifi-psk";

        if (!g_file_get_contents (path, &psk, NULL, NULL))
                return G_SOURCE_REMOVE;
        remove (path);
        g_strchomp (psk);
        if (psk[0] == '\\0')
                return G_SOURCE_REMOVE;
        dagu_wifi_fill_secret_entries (dialog, psk);
        g_timeout_add (150, dagu_wifi_do_ok, dialog);
        return G_SOURCE_REMOVE;
}

void
cc_network_panel_connect_to_wifi_ap (GtkWidget      *toplevel,
                                     NMClient       *client,
                                     NMDevice       *device,
                                     NMAccessPoint  *ap)
{
        NMConnection *connection;
        NMSettingConnection *s_con;
        NMSettingWireless *s_wifi;
        NMSettingWirelessSecurity *s_wsec;
        NM80211ApSecurityFlags rsn_flags;
        GtkWidget *dialog;
        g_autofree char *uuid = NULL;
        const char *key_mgmt = "wpa-psk";

        g_return_if_fail (GTK_IS_WIDGET (toplevel));
        g_return_if_fail (NM_IS_CLIENT (client));
        g_return_if_fail (NM_IS_DEVICE (device));
        g_return_if_fail (NM_IS_ACCESS_POINT (ap));

        /* libnma rejects a NULL connection even though its comment allows one.
         * Build the same minimal profile the 802.1x path uses, with the PSK
         * left empty so the dialog asks before anything is activated.
         */
        rsn_flags = nm_access_point_get_rsn_flags (ap);
        if ((rsn_flags & NM_802_11_AP_SEC_KEY_MGMT_SAE) &&
            !(rsn_flags & NM_802_11_AP_SEC_KEY_MGMT_PSK))
                key_mgmt = "sae";

        connection = nm_simple_connection_new ();
        s_con = (NMSettingConnection *) nm_setting_connection_new ();
        uuid = nm_utils_uuid_generate ();
        g_object_set (s_con,
                      NM_SETTING_CONNECTION_UUID, uuid,
                      NM_SETTING_CONNECTION_TYPE, NM_SETTING_WIRELESS_SETTING_NAME,
                      NULL);
        nm_connection_add_setting (connection, NM_SETTING (s_con));

        s_wifi = (NMSettingWireless *) nm_setting_wireless_new ();
        g_object_set (s_wifi,
                      NM_SETTING_WIRELESS_SSID, nm_access_point_get_ssid (ap),
                      NULL);
        nm_connection_add_setting (connection, NM_SETTING (s_wifi));

        s_wsec = (NMSettingWirelessSecurity *) nm_setting_wireless_security_new ();
        g_object_set (s_wsec, NM_SETTING_WIRELESS_SECURITY_KEY_MGMT, key_mgmt, NULL);
        nm_connection_add_setting (connection, NM_SETTING (s_wsec));

        dialog = GTK_WIDGET (nma_wifi_dialog_new (client, connection, device, ap, FALSE));
        g_object_unref (connection);
        if (dialog == NULL) {
                g_warning ("Could not create the Wi-Fi password dialog");
                return;
        }
        g_message ("Wi-Fi password dialog for the selected network");
        show_wireless_dialog (toplevel, client, dialog);
        gtk_window_present (GTK_WINDOW (dialog));
        g_timeout_add (400, dagu_wifi_try_file_submit, dialog);
}

'''

DEVICE_OLD = '''static void
ap_activated (NetDeviceWifi *self, GtkListBoxRow *row)
{
        CcWifiConnectionRow *c_row;
        NMConnection *connection;
        NMAccessPoint *ap;

        /* The mockups want a row to connecto hidden networks; this could
         * be handeled here. */
        if (!CC_IS_WIFI_CONNECTION_ROW (row))
                return;

        c_row = CC_WIFI_CONNECTION_ROW (row);

        connection = cc_wifi_connection_row_get_connection (c_row);
        ap = cc_wifi_connection_row_best_access_point (c_row);

        if (ap != NULL) {
                if (connection != NULL) {
                        nm_client_activate_connection_async (self->client,
                                                             connection,
                                                             self->device, NULL, self->cancellable,
                                                             connection_activate_cb, self);
                } else {
                        GBytes *ssid;
                        const gchar *object_path;

                        ssid = nm_access_point_get_ssid (ap);
                        object_path = nm_object_get_path (NM_OBJECT (ap));
                        wireless_try_to_connect (self, ssid, object_path);
                }
        }
}'''

DEVICE_NEW = '''static gboolean
ap_is_open (NMAccessPoint *ap)
{
        if (nm_access_point_get_wpa_flags (ap) != NM_802_11_AP_SEC_NONE)
                return FALSE;
        if (nm_access_point_get_rsn_flags (ap) != NM_802_11_AP_SEC_NONE)
                return FALSE;
        if (nm_access_point_get_flags (ap) & NM_802_11_AP_FLAGS_PRIVACY)
                return FALSE;
        return TRUE;
}

/* Timestamp is set only after a connection has succeeded, which is when
 * NetworkManager actually stored the passphrase.
 */
static gboolean
connection_succeeded_before (NMConnection *connection)
{
        NMSettingConnection *s_con;

        if (connection == NULL)
                return FALSE;
        s_con = nm_connection_get_setting_connection (connection);
        return s_con != NULL && nm_setting_connection_get_timestamp (s_con) != 0;
}

static void
ap_activated (NetDeviceWifi *self, GtkListBoxRow *row)
{
        CcWifiConnectionRow *c_row;
        NMConnection *connection;
        NMAccessPoint *ap;

        /* The mockups want a row to connecto hidden networks; this could
         * be handeled here. */
        if (!CC_IS_WIFI_CONNECTION_ROW (row))
                return;

        c_row = CC_WIFI_CONNECTION_ROW (row);

        connection = cc_wifi_connection_row_get_connection (c_row);
        ap = cc_wifi_connection_row_best_access_point (c_row);
        if (ap == NULL)
                return;

        /* dagu: ask for the Wi-Fi password before activating.
         * A profile that has connected before already has its secret, so
         * switching to it can start immediately. A secured network that
         * has never connected must show the dialog while the current
         * network is still up.
         */
        if (connection_succeeded_before (connection)) {
                nm_client_activate_connection_async (self->client,
                                                     connection,
                                                     self->device, NULL, self->cancellable,
                                                     connection_activate_cb, self);
                return;
        }

        if (!ap_is_open (ap)) {
                GtkNative *native = gtk_widget_get_native (GTK_WIDGET (self));

                if (native == NULL)
                        return;
                cc_network_panel_connect_to_wifi_ap (GTK_WIDGET (native),
                                                     self->client,
                                                     self->device,
                                                     ap);
                return;
        }

        if (connection != NULL) {
                nm_client_activate_connection_async (self->client,
                                                     connection,
                                                     self->device, NULL, self->cancellable,
                                                     connection_activate_cb, self);
                return;
        }

        {
                GBytes *ssid;
                const gchar *object_path;

                ssid = nm_access_point_get_ssid (ap);
                object_path = nm_object_get_path (NM_OBJECT (ap));
                wireless_try_to_connect (self, ssid, object_path);
        }
}'''


def patch_header(text: str) -> str:
    if "cc_network_panel_connect_to_wifi_ap" in text:
        return text
    if HEADER_ANCHOR not in text:
        raise SystemExit("header anchor not found")
    return text.replace(HEADER_ANCHOR, HEADER_INSERT + HEADER_ANCHOR, 1)


def upgrade_dialog_connection(text: str) -> str:
    if "dagu_wifi_try_file_submit" in text:
        return text
    start = text.find("void\ncc_network_panel_connect_to_wifi_ap")
    if start < 0:
        return text
    end = text.find("\nvoid\ncc_network_panel_connect_to_hidden_network", start)
    if end < 0:
        raise SystemExit("cannot upgrade the Wi-Fi dialog constructor")
    return text[:start] + PUBLIC_INSERT + text[end + 1:]


def patch_dialogs(text: str) -> str:
    text = upgrade_dialog_connection(text)
    if MARKER in text and "cc_network_panel_connect_to_wifi_ap" in text:
        return text
    if "static void\nwifi_secret_commit_free" not in text:
        anchor = "static void\nwireless_dialog_response_cb"
        if anchor not in text:
            raise SystemExit("wireless_dialog_response_cb not found")
        text = text.replace(anchor, HELPERS + anchor, 1)
    if FUZZY_OLD not in text:
        raise SystemExit("fuzzy activate block not found")
    text = text.replace(FUZZY_OLD, FUZZY_NEW, 1)
    if "cc_network_panel_connect_to_wifi_ap (" not in text:
        if PUBLIC_ANCHOR not in text:
            raise SystemExit("hidden-network function not found")
        text = text.replace(PUBLIC_ANCHOR, PUBLIC_INSERT + PUBLIC_ANCHOR, 1)
    return text


def patch_device(text: str) -> str:
    if MARKER in text:
        return text
    if DEVICE_OLD not in text:
        raise SystemExit("ap_activated not found")
    return text.replace(DEVICE_OLD, DEVICE_NEW, 1)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} panels/network/<file>")
    path = Path(sys.argv[1])
    text = path.read_text()
    name = path.name
    if name == "network-dialogs.h":
        new = patch_header(text)
    elif name == "network-dialogs.c":
        new = patch_dialogs(text)
    elif name == "net-device-wifi.c":
        new = patch_device(text)
    else:
        raise SystemExit(f"unsupported {name}")
    if new == text:
        print(f"already patched {path}")
        return
    path.write_text(new)
    print(f"patched {path}")


if __name__ == "__main__":
    main()
