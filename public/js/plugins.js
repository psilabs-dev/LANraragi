/**
 * Plugins Operations
 */
import * as Server from "./mod/server.js";
import * as LRR from "./mod/common.js";
import I18N from "i18n";

const Plugins = {};

Plugins.registryId = null;
Plugins.manageChanged = false;
Plugins.installedNamespaces = new Set();
Plugins.pendingChanges = new Map();

Plugins.setManageToggleState = function ($toggle, state) {
    const labels = {
        installed: "Installed",
        available: "Available",
        pendingInstall: "Will install",
        pendingUninstall: "Will uninstall",
    };

    $toggle.attr("data-state-label", labels[state] || "");
};

Plugins.initializeAll = function () {
    // Config buttons
    $(document).on("click.save", "#save", () => Server.saveFormData("#editPluginForm"));
    $(document).on("click.return", "#return", () => { window.location.href = new LRR.ApiURL("/"); });

    // Description show more/less toggles
    $(document).on("click", ".plugin-description-toggle", function () {
        const desc = $(this).siblings(".plugin-description");
        desc.toggleClass("expanded");
        $(this).text(desc.hasClass("expanded") ? I18N.ShowLess : I18N.ShowMore);
    });
    // Show toggle only for descriptions that overflow; re-check when collapsibles open
    function checkDescriptionOverflow() {
        $(".plugin-description").each(function () {
            const toggle = this.parentElement.querySelector(".plugin-description-toggle");
            if (!toggle) return;
            if (this.scrollHeight > this.clientHeight + 1) {
                toggle.style.display = "block";
            } else if (!this.classList.contains("expanded")) {
                toggle.style.display = "none";
            }
        });
    }
    // Detect collapsible visibility changes via IntersectionObserver
    var descCheckTimer = null;
    function scheduleDescCheck() {
        clearTimeout(descCheckTimer);
        descCheckTimer = setTimeout(checkDescriptionOverflow, 100);
    }
    var intObs = new IntersectionObserver(function (entries) {
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].isIntersecting) { scheduleDescCheck(); break; }
        }
    });
    $(".plugin-description").each(function () { intObs.observe(this); });

    // File upload handler
    $("#fileupload").fileupload({
        url: "/config/plugins/upload",
        dataType: "json",
        done(e, data) {
            if (data.result.success) {
                Plugins.manageChanged = true;
                LRR.toast({
                    heading: I18N.PluginUploadSuccess,
                    text: I18N.PluginUploadDesc(data.result.name),
                    icon: "info",
                    hideAfter: 10000,
                });
            } else {
                LRR.toast({
                    heading: I18N.PluginUploadError,
                    text: data.result.error,
                    icon: "error",
                    hideAfter: false,
                });
            }
        },
    });

    Plugins.initTabs();

    // Hide available sections until registry data arrives
    $("#manage-sections .manage-available").hide();

    // Load registry into Manage tab
    Plugins.loadRegistrySection();

    // Capture installed namespaces from server-rendered Manage tab rows
    $(".manage-plugin-row[data-installed='1']").each(function () {
        Plugins.installedNamespaces.add($(this).data("namespace"));
        Plugins.setManageToggleState($(this).find(".manage-install-cb"), "installed");
    });

    // Checkbox change handler for batch install/uninstall staging
    $(document).on("change", ".manage-install-cb", function () {
        var ns = $(this).data("namespace");
        var isChecked = $(this).prop("checked");
        var wasInstalled = Plugins.installedNamespaces.has(ns);
        var row = $(this).closest(".manage-plugin-row");

        if (isChecked !== wasInstalled) {
            Plugins.pendingChanges.set(ns, isChecked ? "install" : "uninstall");
            row.removeClass("manage-row--available manage-row--pending-install manage-row--pending-uninstall");
            row.addClass(isChecked ? "manage-row--pending-install" : "manage-row--pending-uninstall");
            Plugins.setManageToggleState($(this), isChecked ? "pendingInstall" : "pendingUninstall");
        } else {
            Plugins.pendingChanges.delete(ns);
            row.removeClass("manage-row--pending-install manage-row--pending-uninstall");
            if (!wasInstalled) row.addClass("manage-row--available");
            Plugins.setManageToggleState($(this), wasInstalled ? "installed" : "available");
        }

        Plugins.updateApplyButton();
    });

    // Apply Changes button
    $(document).on("click", "#manage-apply-btn", function () {
        if (Plugins.pendingChanges.size === 0) return;

        var installList = [], 
            uninstallList = [];
        Plugins.pendingChanges.forEach(function (action, ns) {
            var name = $(".manage-plugin-row").filter(function () { return $(this).data("namespace") === ns; }).find("h2").text().trim() || ns;
            if (action === "install") installList.push(name);
            else uninstallList.push(name);
        });

        var $body = $("<div>");
        if (installList.length) {
            $body.append($("<b>").text("Installing:"), $("<br>"));
            installList.forEach(function (n) { $body.append($("<span>").text(n), $("<br>")); });
            $body.append($("<br>"));
        }
        if (uninstallList.length) {
            $body.append($("<b>").text("Uninstalling:"), $("<br>"));
            uninstallList.forEach(function (n) { $body.append($("<span>").text(n), $("<br>")); });
        }

        LRR.showPopUp({
            title: "Apply Plugin Changes",
            html: $body.html(),
            icon: "question",
            showCancelButton: true,
            confirmButtonText: "Apply",
            reverseButtons: true,
        }).then(function (result) {
            if (result.isConfirmed) {
                Plugins.executeChanges();
            }
        });
    });

    // Preserve height during collapsible animation to prevent jitter.
    $(document).on("click", ".plugin-tab-panel > ul > li.option-flyout > .collapsible-title", function () {
        var $thisLi = $(this).closest("li.option-flyout");
        var $list = $thisLi.closest("ul");
        var sectionId = $thisLi.attr("id");
        if (sectionId) {
            sessionStorage.setItem("pluginOpenSection", sectionId);
        }

        // Stabilize height during animation to prevent jitter
        $list.css("min-height", $list.outerHeight());
        setTimeout(function () { $list.css("min-height", ""); }, 350);
    });

    // Restore previously open section
    var savedSection = sessionStorage.getItem("pluginOpenSection");
    if (savedSection) {
        sessionStorage.removeItem("pluginOpenSection");
        var $section = $("#" + savedSection);
        if ($section.length) {
            $section.find(".collapsible-body").show();
        }
    }
};

//
// Tab switching
//

Plugins.initTabs = function () {
    $(".plugin-tab").on("click", function () {
        var tabId = $(this).data("tab");
        Plugins.activateTab(tabId);
    });

    // Restore tab from URL hash or default to Configure tab
    var hash = window.location.hash.replace("#", "");
    if (hash && $("#" + hash).length) {
        Plugins.doActivateTab(hash);
    }
};

Plugins.activateTab = function (tabId) {
    var currentTab = $(".plugin-tab.active").data("tab");

    // If switching from Manage to Configure after changes, reload for fresh server render
    if (currentTab === "tab-manage" && tabId === "tab-configure" && Plugins.manageChanged) {
        window.location.href = window.location.href.split("#")[0] + "#tab-configure";
        window.location.reload();
        return;
    }

    Plugins.doActivateTab(tabId);
};

Plugins.doActivateTab = function (tabId) {
    $(".plugin-tab").removeClass("active");
    $(".plugin-tab[data-tab='" + tabId + "']").addClass("active");
    $(".plugin-tab-panel").removeClass("active");
    $("#" + tabId).addClass("active");

    // Show/hide Save button based on tab context
    if (tabId === "tab-manage") {
        $("#save").hide();
    } else {
        $("#save").show();
    }

    history.replaceState(null, "", "#" + tabId);

    // Lazy-load available plugins on first visit to Manage tab
    if (tabId === "tab-manage" && Plugins.registryId && !Plugins.availableLoaded) {
        Plugins.refreshAndLoadAvailable(false);
    }
};

//
// Registry: Manage tab — batch install/uninstall
//

Plugins.updateApplyButton = function () {
    var count = Plugins.pendingChanges.size;
    if (count === 0) {
        $("#manage-apply-bar").hide();
        return;
    }
    var installs = 0, 
        uninstalls = 0;
    Plugins.pendingChanges.forEach(function (action) {
        if (action === "install") installs += 1;
        else uninstalls += 1;
    });
    var parts = [];
    if (installs > 0) parts.push(installs + " install" + (installs > 1 ? "s" : ""));
    if (uninstalls > 0) parts.push(uninstalls + " uninstall" + (uninstalls > 1 ? "s" : ""));
    $("#manage-apply-btn").val(I18N.ApplyChanges + " (" + parts.join(", ") + ")");
    $("#manage-apply-bar").show();
};

Plugins.executeChanges = function () {
    $("#manage-apply-btn").prop("disabled", true);

    var promises = [];
    var results = { installed: 0, uninstalled: 0, failed: 0, errors: [] };

    Plugins.pendingChanges.forEach(function (action, ns) {
        var p;
        if (action === "install") {
            var versionKey = $(".manage-install-cb[data-namespace='" + ns + "']").data("version");
            p = fetch(new LRR.ApiURL("/api/plugins/install"), {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ namespace: ns, registry: Plugins.registryId, version: versionKey }),
            }).then(function (r) { return r.json(); }).then(function (data) {
                if (data.success) {
                    results.installed += 1;
                    Plugins.installedNamespaces.add(ns);
                } else {
                    results.failed += 1;
                    results.errors.push(ns + ": " + (data.error || "unknown"));
                }
            }).catch(function () { results.failed += 1; results.errors.push(ns + ": network error"); });
        } else {
            p = fetch(new LRR.ApiURL("/api/plugins/installed/" + ns), {
                method: "DELETE",
            }).then(function (r) { return r.json(); }).then(function (data) {
                if (data.success) {
                    results.uninstalled += 1;
                    Plugins.installedNamespaces.delete(ns);
                } else {
                    results.failed += 1;
                    results.errors.push(ns + ": " + (data.error || "unknown"));
                }
            }).catch(function () { results.failed += 1; results.errors.push(ns + ": network error"); });
        }
        promises.push(p);
    });

    Promise.allSettled(promises).then(function () {
        Plugins.pendingChanges.forEach(function (action, ns) {
            var row = $(".manage-plugin-row").filter(function () { return $(this).data("namespace") === ns; });
            var succeeded = (action === "install" && Plugins.installedNamespaces.has(ns))
                         || (action === "uninstall" && !Plugins.installedNamespaces.has(ns));

            if (succeeded) {
                Plugins.pendingChanges.delete(ns);
                row.removeClass("manage-row--pending-install manage-row--pending-uninstall manage-row--available");
                if (action === "uninstall") {
                    row.addClass("manage-row--available");
                    row.attr("data-installed", "0");
                    row.find(".manage-install-cb").prop("checked", false);
                    Plugins.setManageToggleState(row.find(".manage-install-cb"), "available");
                } else {
                    row.attr("data-installed", "1");
                    row.find(".manage-install-cb").prop("checked", true);
                    Plugins.setManageToggleState(row.find(".manage-install-cb"), "installed");
                }
            }
        });

        var parts = [];
        if (results.installed > 0) parts.push(results.installed + " installed");
        if (results.uninstalled > 0) parts.push(results.uninstalled + " uninstalled");
        if (results.failed > 0) parts.push(results.failed + " failed");

        LRR.toast({
            heading: "Plugin Changes Applied",
            text: parts.join(", ") + (results.errors.length ? "\n" + results.errors.join("\n") : ""),
            icon: results.failed > 0 ? "warning" : "success",
            hideAfter: results.failed > 0 ? false : 5000,
        });

        if (results.installed > 0 || results.uninstalled > 0) {
            Plugins.manageChanged = true;
            window.location.href = window.location.href.split("#")[0] + "#tab-manage";
            window.location.reload();
            return;
        }

        Plugins.updateApplyButton();
        $("#manage-apply-btn").prop("disabled", false);
    });
};

Plugins.availableLoaded = false;

Plugins.loadRegistrySection = function () {
    const statusText = $("#registry-status-text");

    Server.callAPI("/api/registries", "GET", null, I18N.RegistryLoadError,
        (data) => {
            if (data.registries.length === 0) {
                // No registry — show the empty state.
                $("#available-empty").show();
                return;
            }

            const reg = data.registries[0];
            Plugins.registryId = reg.id;

            // Show registry info + refresh button in the Manage tab
            statusText.empty()
                .append($("<i class=\"fa fa-cube\"></i> "))
                .append($("<span>").text(reg.name))
                .append(" \u00a0")
                .append($("<a id=\"registry-refresh-btn\" href=\"#\" class=\"registry-refresh-link\">")
                    .append($("<i class=\"fa fa-sync-alt\"></i> "))
                    .append(document.createTextNode(I18N.RegistryRefreshBtn)));

            // Hide the "no registry" empty state
            $("#available-empty").hide();

            $(document).on("click.registry-refresh", "#registry-refresh-btn", function (e) {
                e.preventDefault();
                Plugins.refreshAndLoadAvailable(true);
            });

            // If user lands directly on the Manage tab, load immediately
            if ($(".plugin-tab[data-tab='tab-manage']").hasClass("active")) {
                Plugins.refreshAndLoadAvailable(false);
            }
        },
    );
};

// Compare two SemVer 2.0.0 version strings by precedence (a < b => negative).
Plugins.compareSemver = function (a, b) {
    const parse = (v) => {
        const core = String(v).split("+")[0];
        const dash = core.indexOf("-");
        const main = dash === -1 ? core : core.slice(0, dash);
        const pre = dash === -1 ? [] : core.slice(dash + 1).split(".");
        return { nums: main.split(".").map((n) => parseInt(n, 10) || 0), pre: pre };
    };
    const pa = parse(a);
    const pb = parse(b);
    for (let i = 0; i < 3; i++) {
        const d = (pa.nums[i] || 0) - (pb.nums[i] || 0);
        if (d !== 0) return d;
    }
    // A version with a prerelease has lower precedence than the associated release.
    if (pa.pre.length === 0 && pb.pre.length > 0) return 1;
    if (pa.pre.length > 0 && pb.pre.length === 0) return -1;
    for (let i = 0; i < Math.max(pa.pre.length, pb.pre.length); i++) {
        if (pa.pre[i] === undefined) return -1;
        if (pb.pre[i] === undefined) return 1;
        if (pa.pre[i] === pb.pre[i]) continue;
        const na = parseInt(pa.pre[i], 10);
        const nb = parseInt(pb.pre[i], 10);
        const aNum = String(na) === pa.pre[i];
        const bNum = String(nb) === pb.pre[i];
        if (aNum && bNum) return na - nb;
        if (aNum) return -1;  // numeric identifiers rank below alphanumeric
        if (bNum) return 1;
        return pa.pre[i] < pb.pre[i] ? -1 : 1;
    }
    return 0;
};

Plugins.refreshAndLoadAvailable = function (userInitiated) {
    if (!Plugins.registryId) return;
    $("#registry-refresh-btn").prop("disabled", true);

    // Get installed namespaces first, then refresh registry. Return the inner call so the
    // outer promise resolves only after the whole flow settles (success or handled error),
    // letting the final .then re-enable the button on every path.
    Server.callAPI("/api/plugins/all", "GET", null, I18N.RegistryRefreshError,
        (installedPlugins) => {
            const installedNamespaces = new Set();
            for (const p of installedPlugins) {
                installedNamespaces.add(p.namespace);
            }

            return Server.callAPI(`/api/registries/${Plugins.registryId}/refresh`, "POST",
                userInitiated ? I18N.RegistryRefreshed : null, I18N.RegistryRefreshError,
                (data) => {
                    Plugins.availableLoaded = true;

                    if (!data.index || !data.index.plugins) return;

                    // Clear old injected rows
                    $(".registry-plugin-row").remove();

                    // Hide all manage-available divs before repopulating
                    $("#manage-sections .manage-available").hide();

                    // Type mapping from registry to Manage tab sections
                    const typeMap = {
                        metadata: "manage-section-metadata",
                        download: "manage-section-download",
                        login: "manage-section-login",
                        script: "manage-section-script",
                    };

                    for (const [ns, meta] of Object.entries(data.index.plugins)) {
                        if (installedNamespaces.has(ns)) continue;

                        const sectionId = typeMap[meta.type];
                        if (!sectionId) continue;

                        const versionKey = Object.keys(meta.versions).sort(Plugins.compareSemver).pop();
                        const versionRecord = meta.versions[versionKey];

                        // Title row: icon + name + author + badge + install button
                        const titleRow = $("<div style=\"display:flex; align-items:center;\">");
                        const titleInfo = $("<div style=\"flex:1;\">");
                        titleInfo.append($("<i class=\"fa fa-puzzle-piece\" style=\"font-size:20px\"></i> "));
                        titleInfo.append($("<h2 class=\"ih\" style=\"display:inline\">").text(" " + versionRecord.name + " v." + versionRecord.version));
                        titleInfo.append($("<h1 class=\"ih\" style=\"display:inline\">").text(" by " + versionRecord.author + " "));
                        titleInfo.append($("<span class=\"plugin-badge plugin-badge--managed\">").text("registry"));
                        titleRow.append(titleInfo);

                        var cb = $("<input type=\"checkbox\" class=\"fa manage-install-cb\">")
                            .attr("data-namespace", ns)
                            .attr("data-version", versionKey);
                        Plugins.setManageToggleState(cb, "available");
                        titleRow.append(cb);

                        // Build the card
                        const card = $("<div class=\"pluginlist-item manage-plugin-row manage-row--available registry-plugin-row\">")
                            .attr("data-namespace", ns)
                            .attr("data-installed", "0");
                        card.append(titleRow);
                        card.append($("<div class=\"plugin-description\">").text(versionRecord.description));

                        // Append to the correct section's available div
                        $("#" + sectionId).find(".manage-available").append(card);
                    }

                    // Show manage-available divs that received content
                    $("#manage-sections .manage-available").each(function () {
                        if ($(this).children(".registry-plugin-row").length > 0) {
                            $(this).show();
                        }
                    });
                },
            );
        },
    ).then(() => {
        // Re-enable the refresh control on every outcome (success, empty, or error).
        $("#registry-refresh-btn").prop("disabled", false);
    });
};

jQuery(() => {
    Plugins.initializeAll();
});
