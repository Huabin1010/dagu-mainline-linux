import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

function writeFile(path, text) {
    const file = Gio.File.new_for_path(path);
    file.replace_contents(
        new TextEncoder().encode(text),
        null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
}

function appendFile(path, text) {
    const file = Gio.File.new_for_path(path);
    const stream = file.append_to(Gio.FileCreateFlags.NONE, null);
    stream.write_all(new TextEncoder().encode(text), null);
    stream.close(null);
}

function safe(fn) {
    try {
        return fn();
    } catch (e) {
        return `err:${e}`;
    }
}

function dumpOnce() {
    const topics = {};
    for (const name of ['KMS', 'KMS_DEADLINE', 'RENDER', 'BACKEND', 'WAYLAND']) {
        if (Meta.DebugTopic[name] !== undefined)
            topics[name] = !!Meta.is_verbose(Meta.DebugTopic[name]);
    }
    let lg = {};
    try {
        const glass = Main.lookingGlass;
        lg = {
            present: !!glass,
            open: !!(glass && (glass.isOpen || glass.open)),
            actor_visible: !!(glass && glass.actor && glass.actor.visible),
        };
    } catch (e) {
        lg = {err: String(e)};
    }
    let clock = {};
    try {
        const st = global.stage;
        const fc = st.get_frame_clock ? st.get_frame_clock() : null;
        clock = {
            has_get_frame_clock: !!st.get_frame_clock,
            clock: fc ? String(fc) : null,
            refresh: safe(() => fc && fc.get_refresh_rate && fc.get_refresh_rate()),
            max_render: safe(() => fc && fc.get_max_render_time_us && fc.get_max_render_time_us()),
        };
        if (fc) {
            const names = ['get_refresh_rate', 'get_priority', 'get_frame_count',
                'get_max_render_time_us', 'get_next_presentation_time'];
            clock.methods = {};
            for (const n of names)
                clock.methods[n] = typeof fc[n];
        }
    } catch (e) {
        clock = {err: String(e)};
    }
    let debugFlags = {};
    try {
        debugFlags = {clutter: String(Clutter.get_debug_flags())};
    } catch (e) {
        debugFlags = {err: String(e)};
    }
    const rec = {
        t: GLib.get_monotonic_time() / 1e6,
        topics,
        lg,
        clock,
        debugFlags,
        paint_flags: String(Meta.get_debug_paint_flags()),
        unsafe: !!(global.context && global.context.unsafe_mode),
    };
    appendFile('/tmp/dagu-lg-dump.jsonl', `${JSON.stringify(rec)}\n`);
    writeFile('/tmp/dagu-lg-last.json', `${JSON.stringify(rec, null, 2)}\n`);
}

export default class DaguLgExtension extends Extension {
    enable() {
        this._topics = [];
        const note = [];
        for (const name of ['KMS', 'KMS_DEADLINE']) {
            try {
                Meta.add_verbose_topic(Meta.DebugTopic[name]);
                this._topics.push(name);
                note.push(`on ${name}`);
            } catch (e) {
                note.push(`fail ${name} ${e}`);
            }
        }
        try {
            Clutter.add_debug_flags(
                0, Clutter.DrawDebugFlag.PAINT_MAX_RENDER_TIME, 0);
            this._draw = true;
            note.push('PAINT_MAX_RENDER_TIME');
        } catch (e) {
            note.push(`draw-fail ${e}`);
        }
        try {
            if (Main.lookingGlass)
                Main.lookingGlass.open();
            else
                note.push('lookingGlass missing');
        } catch (e) {
            note.push(`lg-open ${e}`);
        }
        writeFile('/tmp/dagu-lg-enable.log', `${note.join('\n')}\n`);
        try {
            writeFile('/tmp/dagu-lg-dump.jsonl', '');
        } catch (e) {
        }
        dumpOnce();
        this._poll = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 250, () => {
            dumpOnce();
            return GLib.SOURCE_CONTINUE;
        });
    }

    disable() {
        if (this._poll) {
            GLib.source_remove(this._poll);
            this._poll = 0;
        }
        for (const name of this._topics || []) {
            try {
                Meta.remove_verbose_topic(Meta.DebugTopic[name]);
            } catch (e) {
            }
        }
        if (this._draw) {
            try {
                Clutter.remove_debug_flags(
                    0, Clutter.DrawDebugFlag.PAINT_MAX_RENDER_TIME, 0);
            } catch (e) {
            }
        }
        try {
            if (Main.lookingGlass && Main.lookingGlass.close)
                Main.lookingGlass.close();
        } catch (e) {
        }
        writeFile('/tmp/dagu-lg-disable.log', 'disabled\n');
    }
}
