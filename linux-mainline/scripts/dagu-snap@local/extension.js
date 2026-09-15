import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

Gio._promisify(Shell.Screenshot.prototype, 'screenshot');

function writeMarker(path, text) {
    const file = Gio.File.new_for_path(path);
    file.replace_contents(
        new TextEncoder().encode(text),
        null,
        false,
        Gio.FileCreateFlags.REPLACE_DESTINATION,
        null);
}

function maybeSnap() {
    const want = Gio.File.new_for_path('/tmp/dagu-snap.want');
    if (!want.query_exists(null))
        return;
    try {
        want.delete(null);
    } catch (e) {
    }
    const dest = Gio.File.new_for_path('/tmp/dagu-snap.png');
    try {
        dest.delete(null);
    } catch (e) {
    }
    writeMarker('/tmp/dagu-snap.done', 'starting\n');
    const screenshot = new Shell.Screenshot();
    let stream;
    try {
        stream = dest.replace(null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
    } catch (e) {
        writeMarker('/tmp/dagu-snap.done', `err-open ${e}\n`);
        return;
    }
    screenshot.screenshot(false, stream).then(() => {
        try {
            stream.close(null);
        } catch (e) {
        }
        writeMarker('/tmp/dagu-snap.done', `ok size=${dest.query_info('standard::size', Gio.FileQueryInfoFlags.NONE, null).get_size()}\n`);
    }).catch(e => {
        writeMarker('/tmp/dagu-snap.done', `err ${e}\n`);
    });
}

export default class DaguSnapExtension extends Extension {
    enable() {
        this._poll = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 400, () => {
            maybeSnap();
            return GLib.SOURCE_CONTINUE;
        });
        maybeSnap();
    }

    disable() {
        if (this._poll) {
            GLib.source_remove(this._poll);
            this._poll = 0;
        }
    }
}
