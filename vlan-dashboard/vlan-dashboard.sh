#!/bin/sh
# LuCI VLAN Clients - Modern JS-based LuCI view
# Usage: sh install-vlan-clients.sh

set -e

VIEW_PATH="/www/luci-static/resources/view/vlan-clients.js"
MENU_PATH="/usr/share/luci/menu.d/luci-app-vlan-clients.json"
ACL_PATH="/usr/share/rpcd/acl.d/luci-app-vlan-clients.json"
LABELS_FILE="/etc/vlan-client-labels"

echo "Installing LuCI VLAN Clients (JS framework)..."

mkdir -p "$(dirname $VIEW_PATH)" "$(dirname $MENU_PATH)" "$(dirname $ACL_PATH)"
[ -f "$LABELS_FILE" ] || touch "$LABELS_FILE"

# ── Menu registration ─────────────────────────────────────────────────────────
cat > "$MENU_PATH" << 'EOF'
{
  "admin/network/vlan-clients": {
    "title": "VLAN Clients",
    "order": 70,
    "action": {
      "type": "view",
      "path": "vlan-clients"
    },
    "depends": {
      "acl": ["luci-app-vlan-clients"]
    }
  }
}
EOF
echo "  [OK] Menu written"

# ── ACL ───────────────────────────────────────────────────────────────────────
cat > "$ACL_PATH" << 'EOF'
{
  "luci-app-vlan-clients": {
    "description": "VLAN Clients page",
    "read": {
      "file": {
        "/proc/net/arp": ["read"],
        "/tmp/dhcp.leases": ["read"],
        "/etc/vlan-client-labels": ["read"],
        "/etc/config/network": ["read"]
      }
    },
    "write": {
      "file": {
        "/etc/vlan-client-labels": ["write"]
      }
    }
  }
}
EOF
echo "  [OK] ACL written"

# ── JS View ───────────────────────────────────────────────────────────────────
cat > "$VIEW_PATH" << 'JSEOF'
'use strict';
'require view';
'require rpc';

var LABELS_PATH = '/etc/vlan-client-labels';

var callRead = rpc.declare({
    object: 'file',
    method: 'read',
    params: ['path'],
    expect: { data: '' }
});

var callWrite = rpc.declare({
    object: 'file',
    method: 'write',
    params: ['path', 'data']
});

/* ── Parsers ────────────────────────────────────────────────────────────── */

function parseArp(raw) {
    var byIface = {};
    (raw || '').split('\n').slice(1).forEach(function(line) {
        var p = line.trim().split(/\s+/);
        if (p.length >= 6 && p[2] !== '0x0' && /^br/.test(p[5])) {
            var iface = p[5];
            if (!byIface[iface]) byIface[iface] = [];
            byIface[iface].push({ ip: p[0], mac: p[3].toUpperCase() });
        }
    });
    return byIface;
}

function parseLeases(raw) {
    var leases = {};
    (raw || '').split('\n').forEach(function(line) {
        var p = line.trim().split(/\s+/);
        if (p.length >= 4)
            leases[p[1].toUpperCase()] = { name: p[3] !== '*' ? p[3] : '' };
    });
    return leases;
}

function parseLabels(raw) {
    var labels = {};
    (raw || '').split('\n').forEach(function(line) {
        var m = line.match(/^(\S+)\s+(.+)$/);
        if (m) labels[m[1].toUpperCase()] = m[2].trim();
    });
    return labels;
}

function serializeLabels(labels) {
    return Object.keys(labels)
        .filter(function(k) { return labels[k]; })
        .map(function(mac) { return mac + ' ' + labels[mac]; })
        .join('\n') + '\n';
}

/* Bygger en karta: 'br-lan.20' → 'iot', 'br-lan.1' → 'lan', osv */
function parseNetworkNames(raw) {
    var map = {};
    var cur = null;
    (raw || '').split('\n').forEach(function(line) {
        line = line.trim();
        var m;
        if ((m = line.match(/^config interface '?(\S+?)'?\s*$/)))
            cur = m[1];
        else if (cur && (m = line.match(/^option device '?(\S+?)'?\s*$/)))
            map[m[1]] = cur;
    });
    return map;
}

function ipToNum(ip) {
    return (ip || '0.0.0.0').split('.').reduce(function(a, b) {
        return (a << 8) + parseInt(b || 0, 10);
    }, 0) >>> 0;
}

/* ── Theme-aware styles ─────────────────────────────────────────────────── */

var DARK_VARS =
    '--vc-stripe:rgba(255,255,255,.05);--vc-muted:#bbb;--vc-sub:#777;' +
    '--vc-accent:#fff;--vc-border:#444;--vc-input-bg:#2d2d2d;' +
    '--vc-input-color:#ddd;--vc-input-border:#555;--vc-btn-bg:#3a3a3a;' +
    '--vc-btn-border:#666;--vc-del-bg:#3a1818;--vc-del-border:#a44;' +
    '--vc-del-color:#f88;--vc-edit-bg:#2e2e2e;--vc-edit-border:#555;' +
    '--vc-edit-color:#777;--vc-pill-off-bg:#2e2e2e;--vc-pill-off-border:#555;' +
    '--vc-pill-off-color:#888;--vc-mac:#aaa;--vc-footer:#666';

function injectStyles() {
    if (document.getElementById('vc-style')) return;
    var s = document.createElement('style');
    s.id = 'vc-style';
    s.textContent =
        ':root{--vc-stripe:#f8f8f8;--vc-muted:#555;--vc-sub:#aaa;' +
        '--vc-accent:#1a3566;--vc-border:#ddd;--vc-input-bg:#fff;' +
        '--vc-input-color:inherit;--vc-input-border:#ccc;--vc-btn-bg:#eee;' +
        '--vc-btn-border:#aaa;--vc-del-bg:#fff4f4;--vc-del-border:#e88;' +
        '--vc-del-color:#c00;--vc-edit-bg:#fff;--vc-edit-border:#ccc;' +
        '--vc-edit-color:#999;--vc-pill-off-bg:#f5f5f5;--vc-pill-off-border:#ccc;' +
        '--vc-pill-off-color:#888;--vc-mac:#555;--vc-footer:#999}' +
        '@media(prefers-color-scheme:dark){:root{' + DARK_VARS + '}}' +
        'html.vc-dark{' + DARK_VARS + '}';
    document.head.appendChild(s);
    /* Detect dark themes that don't use prefers-color-scheme (e.g. luci-theme-bootstrap-dark) */
    requestAnimationFrame(function() {
        var bg = getComputedStyle(document.body).backgroundColor;
        var m = bg.match(/\d+/g);
        if (m && m.length >= 3 &&
            (0.299*parseInt(m[0]) + 0.587*parseInt(m[1]) + 0.114*parseInt(m[2])) < 100)
            document.documentElement.classList.add('vc-dark');
    });
}

/* ── View ───────────────────────────────────────────────────────────────── */

return view.extend({

    /* Remove the default Save / Reset buttons at the bottom */
    handleSave: null,
    handleReset: null,
    handleSaveApply: null,

    load: function() {
        return Promise.all([
            callRead('/proc/net/arp'),
            callRead('/tmp/dhcp.leases'),
            callRead(LABELS_PATH),
            callRead('/etc/config/network')
        ]);
    },

    saveLabel: function(mac, value, labelsRaw) {
        var labels = parseLabels(labelsRaw);
        var v = (value || '').trim();
        if (!v) return;
        labels[mac] = v;
        return callWrite(LABELS_PATH, serializeLabels(labels))
            .then(function() { location.reload(); });
    },

    removeLabel: function(mac, labelsRaw) {
        var labels = parseLabels(labelsRaw);
        delete labels[mac];
        return callWrite(LABELS_PATH, serializeLabels(labels))
            .then(function() { location.reload(); });
    },

    sortTable: function(thEl, colIdx) {
        var table  = thEl.closest('table');
        var tbody  = table.querySelector('tbody');
        var rows   = Array.from(tbody.querySelectorAll('tr'));
        var asc    = thEl.dataset.dir !== 'asc';
        thEl.dataset.dir = asc ? 'asc' : 'desc';

        /* reset all arrows, set active */
        table.querySelectorAll('th .sort-icon').forEach(function(s) {
            s.textContent = ' ⇅';
        });
        thEl.querySelector('.sort-icon').textContent = asc ? ' ▲' : ' ▼';

        rows.sort(function(a, b) {
            var av = (a.cells[colIdx] ? a.cells[colIdx].innerText : '').trim();
            var bv = (b.cells[colIdx] ? b.cells[colIdx].innerText : '').trim();
            var numA = /^\d+\.\d+\.\d+\.\d+$/.test(av);
            var numB = /^\d+\.\d+\.\d+\.\d+$/.test(bv);
            if (numA && numB)
                return asc ? ipToNum(av) - ipToNum(bv) : ipToNum(bv) - ipToNum(av);
            return asc ? av.localeCompare(bv) : bv.localeCompare(av);
        });

        rows.forEach(function(r, i) {
            r.style.background = i % 2 ? 'var(--vc-stripe)' : '';
            tbody.appendChild(r);
        });
    },

    mkTh: function(label, col) {
        var self = this;
        var icon = E('span', { class: 'sort-icon' }, [' ⇅']);
        var th = E('th', {
            style: 'padding:8px 14px;background:#4a4a4a;color:#e8e8e8;font-weight:normal;' +
                   'font-size:.92em;letter-spacing:.05em;text-transform:uppercase;' +
                   'white-space:nowrap;cursor:pointer;user-select:none;text-align:left',
            click: function() { self.sortTable(th, col); }
        }, [label, icon]);
        return th;
    },

    mkDeviceCell: function(c, leases, labelsRaw) {
        var self    = this;
        var labels  = parseLabels(labelsRaw);
        var label   = labels[c.mac] || '';
        var hn      = (leases[c.mac] || {}).name || '';
        var primary = label || hn || '—';
        var isLabelled = label !== '';

        /* primary text — no bold, label in blue, plain otherwise */
        var primaryDiv = E('div', {
            style: 'font-size:1em;color:' + (isLabelled ? 'var(--vc-accent)' : 'var(--vc-muted)')
        }, [primary]);

        /* hostname sub-text shown below label (no bold, muted) */
        var hnDiv = (isLabelled && hn)
            ? E('div', { style: 'font-size:.82em;color:var(--vc-sub);margin-top:2px' }, [hn])
            : null;

        /* collapsible edit / add form */
        var inputEl = E('input', {
            type: 'text',
            value: label,
            placeholder: _('Label…'),
            maxlength: 64,
            style: 'width:140px;padding:3px 7px;border:1px solid var(--vc-input-border);' +
                   'border-radius:3px;font-size:.85em;' +
                   'background:var(--vc-input-bg);color:var(--vc-input-color)'
        });

        var formChildren = [inputEl,
            E('button', {
                style: 'padding:3px 10px;font-size:.82em;cursor:pointer;' +
                       'border:1px solid var(--vc-btn-border);border-radius:3px;background:var(--vc-btn-bg);white-space:nowrap',
                click: function(ev) {
                    ev.preventDefault();
                    self.saveLabel(c.mac, inputEl.value, labelsRaw);
                }
            }, [_('Save')])
        ];

        if (isLabelled)
            formChildren.push(E('button', {
                style: 'padding:3px 10px;font-size:.82em;cursor:pointer;white-space:nowrap;' +
                       'border:1px solid var(--vc-del-border);border-radius:3px;background:var(--vc-del-bg);color:var(--vc-del-color)',
                click: function(ev) {
                    ev.preventDefault();
                    self.removeLabel(c.mac, labelsRaw);
                }
            }, [_('Remove')]));

        var formDiv = E('div', {
            style: 'display:none;gap:5px;margin-top:7px;align-items:center;flex-wrap:nowrap'
        }, formChildren);

        /* edit button — hidden by default, shown on row hover via JS */
        var iconBtn = E('button', {
            class: 'vc-edit-btn',
            style: 'width:22px;height:22px;padding:0;flex-shrink:0;' +
                   'border:1.5px solid var(--vc-edit-border);border-radius:5px;' +
                   'background:var(--vc-edit-bg);cursor:pointer;opacity:0;' +
                   'font-size:13px;line-height:1;color:var(--vc-edit-color);' +
                   'display:inline-flex;align-items:center;justify-content:center;' +
                   'transition:opacity .12s,border-color .12s,color .12s',
            title: isLabelled ? _('Edit label') : _('Add label'),
            click: function(ev) {
                ev.stopPropagation();
                var open = formDiv.style.display !== 'none';
                formDiv.style.display = open ? 'none' : 'flex';
                if (!open) inputEl.focus();
            }
        }, [isLabelled ? '✏' : '+']);

        /* top row: name left, edit button right */
        var topRow = E('div', {
            style: 'display:flex;align-items:center;justify-content:space-between;gap:6px'
        }, [primaryDiv, iconBtn]);

        var children = [topRow];
        if (hnDiv) children.push(hnDiv);
        children.push(formDiv);

        var td = E('td', { style: 'padding:12px 16px;vertical-align:top;width:45%' }, children);

        /* hover: show/hide edit button — use closure refs to avoid querySelector bug */
        td.addEventListener('mouseenter', function() {
            iconBtn.style.opacity = '1';
        });
        td.addEventListener('mouseleave', function() {
            if (formDiv.style.display === 'none')
                iconBtn.style.opacity = '0';
        });

        return td;
    },

    renderSection: function(iface, clients, leases, labelsRaw, searchStr, netNames) {
        var self     = this;
        var friendly = (netNames && netNames[iface]) || iface;
        var lsKey    = 'vc-open-' + iface;
        var saved   = localStorage.getItem(lsKey);
        var isOpen  = saved === null ? true : saved === '1';

        /* filter rows by search string — inkluderar labels, hostname, IP, MAC */
        var labels = parseLabels(labelsRaw);
        var filtered = clients.slice().filter(function(c) {
            if (!searchStr) return true;
            var s  = searchStr.toLowerCase();
            var hn = ((leases[c.mac] || {}).name || '').toLowerCase();
            var lb = (labels[c.mac] || '').toLowerCase();
            return c.ip.indexOf(s) !== -1 ||
                   c.mac.toLowerCase().indexOf(s) !== -1 ||
                   hn.indexOf(s) !== -1 ||
                   lb.indexOf(s) !== -1;
        });

        /* sort by IP */
        filtered.sort(function(a, b) { return ipToNum(a.ip) - ipToNum(b.ip); });

        var rows = filtered.map(function(c, i) {
            return E('tr', {
                style: i % 2 ? 'background:var(--vc-stripe)' : ''
            }, [
                self.mkDeviceCell(c, leases, labelsRaw),
                E('td', { style: 'padding:12px 16px;vertical-align:middle;width:20%;font-size:1em' }, [c.ip]),
                E('td', { style: 'padding:12px 16px;vertical-align:middle;width:35%;' +
                                 'font-family:monospace;font-size:.95em;color:var(--vc-mac)' }, [c.mac])
            ]);
        });

        var countLabel = filtered.length !== clients.length
            ? filtered.length + '/' + clients.length
            : clients.length;

        var table = E('table', { style: 'width:100%;border-collapse:collapse' }, [
            E('thead', {}, [E('tr', {}, [
                self.mkTh(_('Device'), 0),
                self.mkTh(_('IP Address'), 1),
                self.mkTh(_('MAC Address'), 2)
            ])]),
            E('tbody', {}, rows)
        ]);

        var arrowEl = E('span', {
            style: 'display:inline-block;font-size:.7em;margin-right:6px;transition:transform .15s'
        }, [isOpen ? '▼' : '▶']);

        var countEl = E('span', {
            style: 'font-weight:normal;font-size:.8em;color:#aaa;margin-left:8px'
        }, ['(' + countLabel + ' ' + _('client(s)') + ')']);

        var ifaceSubEl = (friendly !== iface)
            ? E('span', { style: 'font-size:.72em;color:#aaa;margin-left:7px;font-weight:normal' },
                [iface])
            : null;

        var summaryChildren = [arrowEl, friendly];
        if (ifaceSubEl) summaryChildren.push(ifaceSubEl);
        summaryChildren.push(countEl);

        var summary = E('summary', {
            style: 'background:#383838;color:#fff;padding:11px 16px;cursor:pointer;' +
                   'user-select:none;list-style:none;display:flex;align-items:center;' +
                   'border-radius:4px 4px 0 0;font-size:1em'
        }, summaryChildren);

        var details = E('details', {}, [
            summary,
            E('div', { style: 'border:1px solid var(--vc-border);border-top:none;' +
                               'border-radius:0 0 4px 4px;overflow:hidden;' +
                               'box-shadow:0 1px 4px rgba(0,0,0,.12)' }, [table])
        ]);

        /* restore saved state */
        if (isOpen) details.setAttribute('open', '');

        /* persist on toggle */
        details.addEventListener('toggle', function() {
            localStorage.setItem(lsKey, details.open ? '1' : '0');
            arrowEl.textContent = details.open ? '▼' : '▶';
        });

        return E('div', { 'data-iface': iface, style: 'margin-bottom:1.4em' }, [details]);
    },

    render: function(data) {
        injectStyles();

        var arpRaw    = data[0];
        var leasesRaw = data[1];
        var labelsRaw = data[2];
        var netRaw    = data[3];

        var byIface   = parseArp(arpRaw);
        var leases    = parseLeases(leasesRaw);
        var netNames  = parseNetworkNames(netRaw);
        var ifaces    = Object.keys(byIface).sort();
        var self    = this;

        if (ifaces.length === 0)
            return E('div', {}, [
                E('h2', {}, [_('VLAN Clients')]),
                E('p', { style: 'color:var(--vc-footer);font-style:italic' },
                  [_('No VLAN bridge interfaces found in ARP table.')])
            ]);

        /* ── toolbar: sökruta + VLAN-filter-pills ── */
        var searchEl = E('input', {
            type: 'search',
            placeholder: _('Search hostname, IP, MAC…'),
            style: 'padding:6px 10px;border:1px solid var(--vc-input-border);border-radius:5px;' +
                   'font-size:.9em;width:220px;outline:none;' +
                   'background:var(--vc-input-bg);color:var(--vc-input-color)'
        });

        /* active-set: which VLANs are shown (default all) */
        var hidden = {};
        try {
            var h = JSON.parse(localStorage.getItem('vc-hidden') || '{}');
            if (typeof h === 'object') hidden = h;
        } catch(e) {}

        var sectionsEl = E('div', { style: 'margin-top:1em' });

        function rebuildSections() {
            var q = searchEl.value.trim();
            while (sectionsEl.firstChild) sectionsEl.removeChild(sectionsEl.firstChild);
            ifaces.forEach(function(iface) {
                if (hidden[iface]) return;
                sectionsEl.appendChild(
                    self.renderSection(iface, byIface[iface], leases, labelsRaw, q, netNames)
                );
            });
        }

        searchEl.addEventListener('input', rebuildSections);

        /* pill buttons */
        var pills = ifaces.map(function(iface) {
            var active    = !hidden[iface];
            var friendly  = netNames[iface] || iface;
            var pill = E('button', {
                style: 'padding:4px 12px;border-radius:20px;font-size:.82em;cursor:pointer;' +
                       'border:1.5px solid ' + (active ? '#383838' : 'var(--vc-pill-off-border)') + ';' +
                       'background:' + (active ? '#383838' : 'var(--vc-pill-off-bg)') + ';' +
                       'color:' + (active ? '#fff' : 'var(--vc-pill-off-color)') + ';' +
                       'transition:all .15s;white-space:nowrap',
                click: function() {
                    hidden[iface] = !hidden[iface];
                    localStorage.setItem('vc-hidden', JSON.stringify(hidden));
                    var on = !hidden[iface];
                    pill.style.background    = on ? '#383838' : 'var(--vc-pill-off-bg)';
                    pill.style.borderColor   = on ? '#383838' : 'var(--vc-pill-off-border)';
                    pill.style.color         = on ? '#fff'    : 'var(--vc-pill-off-color)';
                    rebuildSections();
                }
            }, [friendly + ' (' + byIface[iface].length + ')']);
            return pill;
        });

        var toolbar = E('div', {
            style: 'display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:1em'
        }, [searchEl].concat(pills).concat([
            E('a', {
                href: '#',
                style: 'margin-left:auto;font-size:.82em;color:var(--vc-sub);text-decoration:none',
                click: function(ev) { ev.preventDefault(); location.reload(); }
            }, [_('↺ Refresh')])
        ]));

        rebuildSections();

        return E('div', {}, [
            E('h2', {}, [_('VLAN Clients')]),
            toolbar,
            sectionsEl,
            E('p', { style: 'font-size:.78em;color:var(--vc-footer);margin-top:.5em' }, [
                _('Source: ARP table + DHCP leases. Labels in /etc/vlan-client-labels.')
            ])
        ]);
    }
});
JSEOF
echo "  [OK] JS view written"

# ── Clear caches and restart rpcd ─────────────────────────────────────────────
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true

echo ""
echo "Done! Open LuCI → Network → VLAN Clients"
echo "(Log out and back in if the menu item is missing.)"
