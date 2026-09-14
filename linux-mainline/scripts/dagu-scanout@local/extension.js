import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// SM8250 has no SSPP 270°. Mutter destiles through the onscreen + view
// transform. Empty queue_redraw does not produce a KMS kickoff, so Chrome
// WaitForSwap / linux-drm-syncobj can sit on poll_schedule_timeout
// for 80–180 ms (slow homepage cover refresh).
//
// 1×1 damage forces a real commit + release, but stacking it on a
// live Chrome destile (always, or after a 24–50 ms hole) is itself
// a 100–340 ms kickoff gap. Touch / fling: schedule_update only.
// Idle maximized: 1×1 at TICK_MS.
const HOLD_US = 800 * 1000;
const TICK_MS = 8;
const DUMP_PATH = '/run/user/1001/dagu-scanout.json';
const FS_FLAG = '/run/user/1001/dagu-want-fullscreen';

export default class DaguPresentPumpExtension extends Extension {
    enable() {
        this._until = 0;
        this._pump = 0;
        this._dump = 0;
        this._nudgeBit = 0;
        this._skipped = 0;
        this._fsOwned = false;
        this._stage = global.stage;
        // Maximized Chrome is culled (paint box 0×0) when mutter thinks
        // the surface is unredirected / empty-unobscured after 270°+1.25.
        // No KMS overlay exists (single gnome-shell plane). Force compose.
        try {
            const compositor = global.display.get_compositor();
            if (compositor && typeof compositor.disable_unredirect === 'function')
                compositor.disable_unredirect();
        } catch (_e) {
        }
        this._dot = new St.Bin({
            width: 1,
            height: 1,
            opacity: 1,
            reactive: false,
            x: 0,
            y: 0,
            style: 'background-color: rgba(0,0,0,0.02);',
        });
        this._stage.add_child(this._dot);
        this._handler = this._stage.connect('captured-event', (_s, ev) => {
            switch (ev.type()) {
            case Clutter.EventType.TOUCH_BEGIN:
            case Clutter.EventType.TOUCH_UPDATE:
            case Clutter.EventType.BUTTON_PRESS:
            case Clutter.EventType.MOTION:
                this._until = GLib.get_monotonic_time() + HOLD_US;
                break;
            default:
                break;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        try {
            this._skipH = this._stage.connect('skipped-paint', () => {
                this._skipped += 1;
            });
        } catch (_e) {
            this._skipH = 0;
        }
        this._pump = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TICK_MS, () => {
            try {
                const mode = this._pumpMode();
                /* Always tick the clock for a maximized/fullscreen client.
                 * libdagu-mutter-release.so turns a skipped tick into
                 * wl_buffer.release / syncobj so we must not 1×1 destile. */
                if (mode === 'touch' || mode === 'idle')
                    this._tickClock();
            } catch (_e) {
            }
            return GLib.SOURCE_CONTINUE;
        });
        this._dump = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, () => {
            this._maybeFullscreen();
            this._writeDump();
            return GLib.SOURCE_CONTINUE;
        });
        this._writeDump();
    }

    _tickClock() {
        if (typeof this._stage.schedule_update === 'function')
            this._stage.schedule_update();
        else
            this._stage.queue_redraw();
        // Without this, Chrome damage is still culled after 270° even
        // with scale-monitor-framebuffer off (100506: 17 slow holes).
        // Do not 1×1 destile the stage.
        try {
            const win = global.display.focus_window;
            const actor = win ? win.get_compositor_private() : null;
            if (actor && typeof actor.queue_redraw === 'function') {
                actor.queue_redraw();
                const kids = typeof actor.get_children === 'function'
                    ? actor.get_children() : [];
                for (const ch of kids) {
                    if (ch && typeof ch.queue_redraw === 'function')
                        ch.queue_redraw();
                }
            }
        } catch (_e) {
        }
    }

    _nudge() {
        this._nudgeBit ^= 1;
        this._dot.opacity = this._nudgeBit ? 2 : 1;
        this._dot.set_position(this._nudgeBit, 0);
    }

    _pumpMode() {
        if (GLib.get_monotonic_time() < this._until)
            return 'touch';
        const win = global.display.focus_window;
        if (!win)
            return '';
        let maxed = false;
        try {
            maxed = typeof win.is_maximized === 'function'
                ? win.is_maximized()
                : (typeof win.get_maximized === 'function'
                    ? win.get_maximized() !== Meta.MaximizeFlags.NONE
                    : false);
        } catch (_e) {
            maxed = false;
        }
        if (maxed || win.is_fullscreen())
            return 'idle';
        return '';
    }

    _maybeFullscreen() {
        try {
            const want = GLib.file_test(FS_FLAG, GLib.FileTest.EXISTS);
            const win = global.display.focus_window;
            if (!win)
                return;
            if (want && !win.is_fullscreen()) {
                win.make_fullscreen();
                this._fsOwned = true;
            } else if (!want && this._fsOwned && win.is_fullscreen()) {
                win.unmake_fullscreen();
                this._fsOwned = false;
            }
        } catch (_e) {
        }
    }

    _writeDump() {
        const info = {
            t_us: GLib.get_monotonic_time(),
            skipped_paint: this._skipped,
            views: [],
            window: null,
        };
        try {
            let views = [];
            if (typeof this._stage.peek_stage_views === 'function')
                views = this._stage.peek_stage_views() || [];
            else if (typeof this._stage.get_stage_views === 'function')
                views = this._stage.get_stage_views() || [];
            for (const v of views) {
                const row = {};
                try {
                    row.shadowfb = v.has_shadowfb();
                } catch (_e) {
                    row.shadowfb = null;
                }
                try {
                    row.scale = v.get_scale();
                } catch (_e) {
                    row.scale = null;
                }
                try {
                    const layout = v.get_layout();
                    row.layout = {
                        x: layout.x, y: layout.y,
                        w: layout.width, h: layout.height,
                    };
                } catch (_e) {
                    row.layout = null;
                }
                try {
                    row.transform = v.get_transform();
                } catch (_e) {
                    row.transform = null;
                }
                info.views.push(row);
            }
        } catch (e) {
            info.views_error = String(e);
        }
        try {
            const win = global.display.focus_window;
            if (win) {
                const fr = win.get_frame_rect();
                const br = win.get_buffer_rect();
                const actor = win.get_compositor_private();
                const row = {
                    wm: win.get_wm_class(),
                    title: win.get_title(),
                    maximized: (typeof win.is_maximized === 'function')
                        ? win.is_maximized() : null,
                    fullscreen: win.is_fullscreen(),
                    frame: {x: fr.x, y: fr.y, w: fr.width, h: fr.height},
                    buffer: {x: br.x, y: br.y, w: br.width, h: br.height},
                };
                if (actor) {
                    try {
                        const box = actor.get_allocation_box();
                        row.alloc = {
                            x1: box.x1, y1: box.y1, x2: box.x2, y2: box.y2,
                        };
                    } catch (_e) {
                    }
                    try {
                        const pb = new Clutter.ActorBox();
                        if (actor.get_paint_box(pb)) {
                            row.paint = {
                                x1: pb.x1, y1: pb.y1, x2: pb.x2, y2: pb.y2,
                            };
                        }
                    } catch (_e) {
                    }
                }
                info.window = row;
            }
        } catch (e) {
            info.window_error = String(e);
        }
        try {
            GLib.file_set_contents(DUMP_PATH, JSON.stringify(info, null, 2));
        } catch (e) {
            info.dump_error = String(e);
            try {
                GLib.file_set_contents('/tmp/dagu-scanout.json', JSON.stringify(info, null, 2));
            } catch (_e2) {
            }
        }
    }

    disable() {
        if (this._handler) {
            this._stage.disconnect(this._handler);
            this._handler = 0;
        }
        if (this._skipH) {
            this._stage.disconnect(this._skipH);
            this._skipH = 0;
        }
        if (this._pump) {
            GLib.source_remove(this._pump);
            this._pump = 0;
        }
        if (this._dump) {
            GLib.source_remove(this._dump);
            this._dump = 0;
        }
        if (this._dot) {
            this._dot.destroy();
            this._dot = null;
        }
    }
}
