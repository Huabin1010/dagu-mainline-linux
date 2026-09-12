import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// Chrome text-input-v3 never sends show_input_panel. Landscape OSK
// _relayout() uses key-grid minHeight that can exceed half the short
// side (1280x800 @200%), so the actor sits off-screen.
export default class DaguOskFocus extends Extension {
    enable() {
        this._im = Main.inputMethod;
        this._openTimeout = 0;
        this._conns = [];
        this._connect(this._im, 'notify::current-focus', () => {
            if (this._im.currentFocus)
                this._openSoon(50);
        });
        this._connect(this._im, 'cursor-location-changed', () => this._openSoon(50));
        this._connect(Main.layoutManager, 'monitors-changed', () => {
            this._patchRelayout();
            if (this._im.currentFocus)
                this._openSoon(120);
        });
        this._connect(global.stage, 'captured-event', (_a, event) => {
            this._maybeChromeOmnibox(event);
            return Clutter.EVENT_PROPAGATE;
        });
        this._patchRelayout();
    }

    _connect(obj, sig, cb) {
        this._conns.push([obj, obj.connect(sig, cb)]);
    }

    _patchRelayout() {
        const kbd = Main.keyboard?.keyboardActor;
        if (!kbd || kbd._daguRelayout)
            return;
        kbd._daguRelayout = true;
        const orig = kbd._relayout.bind(kbd);
        kbd._relayout = () => {
            orig();
            const mon = Main.layoutManager.keyboardMonitor;
            if (!mon)
                return;
            kbd.width = mon.width;
            if (mon.width > mon.height)
                kbd.height = Math.round(Math.min(mon.height * 0.46, 380));
        };
    }

    _eventXY(event) {
        try {
            const c = event.get_coords();
            if (Array.isArray(c))
                return [c[0], c[1]];
            if (c && 'x' in c)
                return [c.x, c.y];
        } catch (e) {
        }
        return [0, 0];
    }

    _maybeChromeOmnibox(event) {
        const type = event.type();
        if (type !== Clutter.EventType.TOUCH_BEGIN &&
            type !== Clutter.EventType.BUTTON_PRESS)
            return;
        const win = global.display.focus_window;
        if (!win)
            return;
        const wm = `${win.get_wm_class() || ''} ${win.get_title() || ''}`;
        if (!/chrome|chromium|google-chrome/i.test(wm))
            return;
        const [x, y] = this._eventXY(event);
        const rect = win.get_frame_rect();
        const band = Math.max(80, Math.round(rect.height * 0.14));
        if (x < rect.x || x > rect.x + rect.width)
            return;
        if (y < rect.y || y > rect.y + band)
            return;
        this._openSoon(80);
    }

    _openSoon(ms) {
        if (this._openTimeout)
            GLib.source_remove(this._openTimeout);
        this._openTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            this._openTimeout = 0;
            this._open();
            return GLib.SOURCE_REMOVE;
        });
    }

    _open() {
        this._patchRelayout();
        const idx = Main.layoutManager.focusIndex;
        Main.layoutManager.keyboardIndex = idx;
        Main.keyboard?.open(idx);
        const kbd = Main.keyboard?.keyboardActor;
        kbd?._relayout?.();
        kbd?.open?.(true);
    }

    disable() {
        if (this._openTimeout) {
            GLib.source_remove(this._openTimeout);
            this._openTimeout = 0;
        }
        for (const [obj, id] of this._conns)
            obj.disconnect(id);
        this._conns = [];
    }
}
