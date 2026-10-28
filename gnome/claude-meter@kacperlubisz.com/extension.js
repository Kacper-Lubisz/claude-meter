// Claude Meter in the GNOME top bar. It only draws what `claude-meter status --json` reports:
// the forecasts, comparisons and wording all come from the Swift command, shared with the macOS app.
import Cairo from 'cairo';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

// The command only calls the usage API every pollSeconds; in between it just moves forecasts on.
const TICK_SECONDS = 30;

// The macOS bar's systemGreen / systemOrange / systemRed (dark variants), as Cairo RGB.
const STATUS_RGB = {ok: [0.19, 0.82, 0.35], warn: [1.0, 0.62, 0.04], over: [1.0, 0.27, 0.23]};

function findCommand() {
    const local = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'claude-meter']);
    if (GLib.file_test(local, GLib.FileTest.IS_EXECUTABLE))
        return local;
    return GLib.find_program_in_path('claude-meter');
}

function toneClass(tone) {
    return tone ? `claude-meter-${tone}` : '';
}

/** The menu bar's mini bar: fill = used, tick = working time elapsed, red cap = projected overshoot. */
function panelBar(item) {
    const area = new St.DrawingArea({style_class: 'claude-meter-bar', y_align: Clutter.ActorAlign.CENTER});
    area.connect('repaint', a => {
        const cr = a.get_context();
        const [w, h] = a.get_surface_size();
        const u = h / 10; // the bar is 10 units tall in the stylesheet, whatever the scale factor
        const trackW = w - 3 * u;
        const fg = a.get_theme_node().get_foreground_color();
        const rgb = [fg.red / 255, fg.green / 255, fg.blue / 255];

        cr.setSourceRGBA(...rgb, 0.3);
        cr.rectangle(0, 2 * u, trackW, 6 * u);
        cr.fill();
        if (item.used !== undefined) {
            cr.setSourceRGBA(...(item.status && item.status !== 'ok' ? STATUS_RGB[item.status] : rgb), 1);
            cr.rectangle(0, 2 * u, trackW * item.used, 6 * u);
            cr.fill();
        }
        if (item.elapsed !== undefined) {
            const x = Math.round(trackW * Math.min(1, item.elapsed));
            // Knock a gap out of the fill so the tick reads on top of fill of the same colour.
            cr.setOperator(Cairo.Operator.CLEAR);
            cr.rectangle(x - 1.75 * u, 0, 3.5 * u, h);
            cr.fill();
            cr.setOperator(Cairo.Operator.OVER);
            cr.setSourceRGBA(...rgb, 1);
            cr.rectangle(x - 0.75 * u, 0, 1.5 * u, h);
            cr.fill();
        }
        if (item.status === 'over') {
            cr.setSourceRGBA(...STATUS_RGB.over, 1);
            cr.rectangle(trackW, 0, 3 * u, h);
            cr.fill();
        }
        cr.$dispose();
    });
    return area;
}

function rowBar(fraction) {
    const track = new St.BoxLayout({style_class: 'claude-meter-rowbar', y_align: Clutter.ActorAlign.CENTER});
    const fill = new St.Widget({style_class: 'claude-meter-rowbar-fill'});
    fill.set_style(`width: ${Math.max(1, Math.round(64 * fraction))}px;`);
    track.add_child(fill);
    return track;
}

function rowItem(row) {
    const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, style_class: 'claude-meter-row'});
    item.add_child(new St.Label({
        text: row.label, x_expand: true, y_align: Clutter.ActorAlign.CENTER,
        style_class: row.emphasis ? 'claude-meter-headline' : 'claude-meter-key',
    }));
    if (row.bar !== undefined)
        item.add_child(rowBar(row.bar));
    item.add_child(new St.Label({
        text: row.value, y_align: Clutter.ActorAlign.CENTER,
        style_class: `claude-meter-value ${toneClass(row.tone)}`,
    }));
    return item;
}

function noteItem(text, tone) {
    const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, style_class: 'claude-meter-row'});
    item.add_child(new St.Label({text, x_expand: true, style_class: toneClass(tone)}));
    return item;
}

function titleItem(section) {
    const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false, style_class: 'claude-meter-row'});
    item.add_child(new St.Label({text: section.title.toUpperCase(), x_expand: true, style_class: 'claude-meter-title'}));
    if (section.note)
        item.add_child(new St.Label({text: section.note, style_class: 'claude-meter-muted'}));
    return item;
}

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init() {
        super._init(0.5, 'Claude Meter');
        this._busy = false;
        this._submenus = [];
        this._cancellable = new Gio.Cancellable();
        this._box = new St.BoxLayout({style_class: 'claude-meter-panel', y_align: Clutter.ActorAlign.CENTER});
        this.add_child(this._box);
        this._showProblem('Claude…', null);

        this.menu.connect('open-state-changed', (_menu, open) => {
            if (open)
                this._run(['status', '--json']);
        });
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, TICK_SECONDS, () => {
            this._run(['status', '--json']);
            return GLib.SOURCE_CONTINUE;
        });
        this.connect('destroy', () => {
            GLib.source_remove(this._timer);
            this._cancellable.cancel();
        });
        this._run(['status', '--json']);
    }

    _run(args) {
        if (this._busy)
            return;
        const command = findCommand();
        if (!command) {
            this._showProblem('Claude ⚠', 'claude-meter not found. Install it with scripts/install-linux.sh.');
            return;
        }
        let proc;
        try {
            proc = Gio.Subprocess.new([command, ...args], Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            this._showProblem('Claude ⚠', e.message);
            return;
        }
        this._busy = true;
        proc.communicate_utf8_async(null, this._cancellable, (p, result) => {
            this._busy = false;
            try {
                const [, stdout, stderr] = p.communicate_utf8_finish(result);
                if (!p.get_successful())
                    throw new Error(stderr.trim() || `claude-meter exited with status ${p.get_exit_status()}`);
                this._show(JSON.parse(stdout));
            } catch (e) {
                if (e instanceof GLib.Error && e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED))
                    return;
                this._showProblem('Claude ⚠', e.message);
            }
        });
    }

    _show(report) {
        this._drawPanel(report);
        // Rebuilding the menu would fold up a submenu that's being read.
        if (!this._submenus.some(sub => sub.menu.isOpen))
            this._drawMenu(report);
    }

    _showProblem(text, detail) {
        this._box.destroy_all_children();
        this._box.add_child(new St.Label({text, y_align: Clutter.ActorAlign.CENTER}));
        this.menu.removeAll();
        this._submenus = [];
        if (detail)
            this.menu.addMenuItem(rowItem({label: detail, value: ''}));
        this._addActions();
    }

    _drawPanel(report) {
        this._box.destroy_all_children();
        if (report.message) {
            this._box.add_child(new St.Label({text: report.message, y_align: Clutter.ActorAlign.CENTER}));
            return;
        }
        if (report.status) {
            this._box.add_child(new St.Widget({
                style_class: `claude-meter-dot claude-meter-dot-${report.status}`, y_align: Clutter.ActorAlign.CENTER,
            }));
        }
        for (const item of report.items) {
            const group = new St.BoxLayout({style_class: 'claude-meter-item', y_align: Clutter.ActorAlign.CENTER});
            group.add_child(new St.Label({text: item.label, style_class: 'claude-meter-label', y_align: Clutter.ActorAlign.CENTER}));
            group.add_child(panelBar(item));
            group.add_child(new St.Label({
                text: item.value, y_align: Clutter.ActorAlign.CENTER,
                style_class: `claude-meter-percent ${item.status && item.status !== 'ok' ? toneClass(item.status) : ''}`,
            }));
            if (item.detail) {
                group.add_child(new St.Label({
                    text: item.detail, y_align: Clutter.ActorAlign.CENTER, style_class: 'claude-meter-detail claude-meter-over',
                }));
            }
            this._box.add_child(group);
        }
    }

    _drawMenu(report) {
        this.menu.removeAll();
        this._submenus = [];
        for (const section of report.sections) {
            if (section.kind === 'window') {
                this.menu.addMenuItem(titleItem(section));
                for (const row of section.rows)
                    this.menu.addMenuItem(rowItem(row));
                this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            } else {
                const sub = new PopupMenu.PopupSubMenuMenuItem(section.title);
                if (section.note)
                    sub.menu.addMenuItem(rowItem({label: section.note, value: '', tone: 'muted'}));
                for (const row of section.rows)
                    sub.menu.addMenuItem(rowItem(row));
                this.menu.addMenuItem(sub);
                this._submenus.push(sub);
            }
        }
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        if (report.outdated)
            this.menu.addMenuItem(noteItem(report.outdated, 'warn'));
        for (const line of report.footer)
            this.menu.addMenuItem(rowItem({label: line, value: '', tone: 'muted'}));
        this._addActions();
    }

    _addActions() {
        const refresh = new PopupMenu.PopupMenuItem('Refresh');
        refresh.connect('activate', () => this._run(['refresh', '--json']));
        this.menu.addMenuItem(refresh);
        const settings = new PopupMenu.PopupMenuItem('Settings');
        settings.connect('activate', () => {
            const path = GLib.build_filenamev([GLib.get_user_config_dir(), 'claude-meter', 'config.json']);
            Gio.AppInfo.launch_default_for_uri(GLib.filename_to_uri(path, null), null);
        });
        this.menu.addMenuItem(settings);
    }
});

export default class ClaudeMeterExtension extends Extension {
    enable() {
        this._indicator = new Indicator();
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
