/**
 * Plugins Operations
 * @global
 */
const Plugins = {};

Plugins.registryId = null;

Plugins.initializeAll = function () {
    // Config buttons
    $(document).on("click.save", "#save", Plugins.saveConfiguration);
    $(document).on("click.return", "#return", () => { window.location.href = new LRR.apiURL("/"); });

    // Uninstall buttons (delegated)
    $(document).on("click", ".plugin-uninstall-btn", function () {
        Plugins.uninstallPlugin($(this).data("namespace"));
    });

    // File upload handler
    $("#fileupload").fileupload({
        url: "/config/plugins/upload",
        dataType: "json",
        done(e, data) {
            if (data.result.success) {
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

    // Initialize SortableJS two-pool drag-and-drop for metadata
    Plugins.initSortable();

    // Load registry section
    Plugins.loadRegistrySection();
};

//
// SortableJS two-pool metadata ordering
//

Plugins.initSortable = function () {
    const enabledEl = document.getElementById("metadata-enabled");
    const disabledEl = document.getElementById("metadata-disabled");

    if (!enabledEl || !disabledEl) return;

    Sortable.create(enabledEl, {
        group: "metadata-plugins",
        animation: 150,
        delay: 150,
        delayOnTouchOnly: true,
        ghostClass: "sortable-ghost",
        chosenClass: "sortable-chosen",
        swapThreshold: 0.65,
        onEnd: Plugins.renumberEnabled,
        onAdd: function () {
            $(enabledEl).find(".pool-empty-msg").remove();
            Plugins.renumberEnabled();
        },
        onRemove: function () {
            if ($(enabledEl).find(".plugin-card").length === 0) {
                $(enabledEl).append('<div class="pool-empty-msg">' + I18N.PoolEmptyEnabled + "</div>");
            }
            Plugins.renumberEnabled();
        },
    });

    Sortable.create(disabledEl, {
        group: "metadata-plugins",
        animation: 150,
        delay: 150,
        delayOnTouchOnly: true,
        ghostClass: "sortable-ghost",
        chosenClass: "sortable-chosen",
        sort: false,
        filter: ".registry-plugin-row",
        onAdd: function (evt) {
            // Remove order badge when moved to disabled pool
            const badge = evt.item.querySelector(".plugin-order-badge");
            if (badge) badge.remove();
            $(disabledEl).find(".pool-empty-msg").remove();
            // Re-sort disabled pool alphabetically
            Plugins.sortDisabledPool();
        },
        onRemove: function () {
            if ($(disabledEl).find(".plugin-card").length === 0) {
                $(disabledEl).append('<div class="pool-empty-msg">' + I18N.PoolEmptyDisabled + "</div>");
            }
        },
    });
};

Plugins.sortDisabledPool = function () {
    const pool = $("#metadata-disabled");
    const cards = pool.children(".plugin-card").get();
    cards.sort(function (a, b) {
        const nameA = $(a).find("h2").text().trim().toLowerCase();
        const nameB = $(b).find("h2").text().trim().toLowerCase();
        return nameA.localeCompare(nameB);
    });
    for (const card of cards) {
        pool.append(card);
    }
};

Plugins.renumberEnabled = function () {
    $("#metadata-enabled .plugin-card").each(function (idx) {
        let badge = $(this).find(".plugin-order-badge");
        if (badge.length === 0) {
            badge = $('<span class="plugin-order-badge"></span>');
            $(this).prepend(badge);
        }
        badge.text(idx + 1);
    });
};

//
// Save configuration
//

Plugins.savePriority = function (namespace, priority) {
    const url = new LRR.apiURL(`/api/plugins/installed/${namespace}/config`);
    return fetch(url, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ priority }),
    }).then((response) => {
        if (!response.ok) throw new Error(I18N.GenericReponseError);
        return response.json();
    }).then((data) => {
        if (Object.prototype.hasOwnProperty.call(data, "success") && !data.success) {
            throw new Error(data.error);
        }
    });
};

Plugins.saveConfiguration = function () {
    // Collect enabled metadata plugin namespaces in order (exclude registry cards)
    const enabledOrder = [];
    $("#metadata-enabled .plugin-card:not(.registry-plugin-row)").each(function () {
        enabledOrder.push($(this).data("namespace"));
    });

    // Collect disabled metadata plugin namespaces (exclude registry cards)
    const disabledList = [];
    $("#metadata-disabled .plugin-card:not(.registry-plugin-row)").each(function () {
        disabledList.push($(this).data("namespace"));
    });

    // Inject hidden inputs for enabled metadata plugins so save_config sees them as checked
    $("#editPluginForm .metadata-enabled-input").remove();
    for (const ns of enabledOrder) {
        $("<input>").attr({ type: "hidden", name: ns, value: "1", class: "metadata-enabled-input" })
            .appendTo("#editPluginForm");
    }

    // Save form data; only proceed with priority saves on success
    const postData = new FormData($("#editPluginForm")[0]);
    fetch(window.location.href, { method: "POST", body: postData })
        .then((response) => (response.ok ? response.json() : { success: 0, error: I18N.GenericReponseError }))
        .then((data) => {
            if (!data.success) {
                throw new Error(data.error || data.message);
            }

            // Persist priority for each metadata plugin
            const promises = [];

            for (let i = 0; i < enabledOrder.length; i++) {
                promises.push(Plugins.savePriority(enabledOrder[i], i));
            }

            for (const ns of disabledList) {
                promises.push(Plugins.savePriority(ns, 0));
            }

            return Promise.all(promises);
        })
        .then(() => {
            LRR.toast({
                heading: I18N.PluginSaved,
                icon: "success",
                hideAfter: 5000,
            });
        })
        .catch((error) => LRR.showErrorToast(I18N.PluginSaveError, error));
};

//
// Registry: available plugins section
//

Plugins.loadRegistrySection = function () {
    const bar = $("#registry-bar");
    const statusText = $("#registry-status-text");

    Server.callAPI("/api/registries", "GET", null, I18N.RegistryLoadError,
        (data) => {
            if (data.registries.length === 0) {
                statusText.html(
                    I18N.RegistryNone + ' <a href="' + new LRR.apiURL("/config") + '">' + I18N.RegistryAddSettings + "</a>",
                );
                bar.show();
                return;
            }

            const reg = data.registries[0];
            Plugins.registryId = reg.id;

            statusText.html(
                "<b>" + I18N.RegistryLabel + "</b> " + $("<span>").text(reg.name).html()
                + " (" + $("<span>").text(reg.type).html() + ") &nbsp;"
                + '<input id="registry-refresh-btn" class="stdbtn" type="button" value="' + I18N.RegistryRefreshBtn + '" />',
            );
            bar.show();

            $(document).on("click.registry-refresh", "#registry-refresh-btn", Plugins.refreshAndLoadAvailable);
        },
    );
};

Plugins.refreshAndLoadAvailable = function () {
    if (!Plugins.registryId) return;
    $("#registry-refresh-btn").prop("disabled", true);

    // Get installed namespaces first, then refresh registry
    Server.callAPI("/api/plugins/all", "GET", null, I18N.RegistryRefreshError,
        (installedPlugins) => {
            const installedNamespaces = new Set();
            for (const p of installedPlugins) {
                installedNamespaces.add(p.namespace);
            }

            Server.callAPI(`/api/registries/${Plugins.registryId}/refresh`, "POST",
                I18N.RegistryRefreshed, I18N.RegistryRefreshError,
                (data) => {
                    $("#registry-refresh-btn").prop("disabled", false);

                    if (!data.index || !data.index.plugins) return;

                    // Clear old injected rows
                    $(".registry-plugin-row").remove();

                    // Type mapping from registry to section container IDs
                    const typeMap = {
                        metadata: "metadata-disabled",
                        download: "registry-download",
                        login: "registry-login",
                        script: "registry-script",
                    };

                    for (const [ns, meta] of Object.entries(data.index.plugins)) {
                        if (installedNamespaces.has(ns)) continue;

                        const containerId = typeMap[meta.type];
                        if (!containerId) continue;

                        // Build card matching the server-rendered plugin-card structure
                        const card = $('<div class="plugin-card registry-plugin-row" data-namespace="' + ns + '">');

                        // Drag handle (visual only for registry cards)
                        card.append($('<div class="drag-handle"><i class="fa fa-grip-vertical"></i></div>'));

                        // Content wrapper
                        const content = $('<div style="flex:1; min-width:0;">');

                        // Title row: icon + name + author + badge + install button
                        const titleRow = $('<div style="display:flex; align-items:center;">');
                        const titleInfo = $('<div style="flex:1;">');
                        titleInfo.append($('<i class="fa fa-puzzle-piece" style="font-size:20px"></i> '));
                        titleInfo.append($('<h2 class="ih" style="display:inline">').text(" " + meta.name + " v." + meta.version));
                        titleInfo.append($('<h1 class="ih" style="display:inline">').text(" by " + meta.author + " "));
                        titleInfo.append($('<span class="plugin-badge plugin-badge--managed">').text("registry"));
                        titleRow.append(titleInfo);

                        const installBtn = $('<input class="stdbtn" type="button">')
                            .val(I18N.PluginInstallBtn)
                            .css({ "flex-shrink": "0", "margin-left": "8px" });
                        installBtn.on("click", () => Plugins.installPlugin(ns));
                        titleRow.append(installBtn);

                        content.append(titleRow);
                        content.append($("<span>").text(meta.description));

                        card.append(content);

                        // Remove the empty-state message before appending the first card
                        $("#" + containerId).siblings("[data-type-empty]").remove();
                        $("#" + containerId).append(card);
                    }
                },
            );
        },
    );
};

Plugins.installPlugin = function (namespace) {
    if (!Plugins.registryId) return;

    Server.callAPIJSON("/api/plugins/install", "POST",
        { namespace: namespace, registry: Plugins.registryId },
        I18N.PluginInstalled(namespace), I18N.PluginInstallError,
        () => {
            // Reload page to reflect new plugin
            window.location.reload();
        },
    );
};

Plugins.uninstallPlugin = function (namespace) {
    LRR.showPopUp({
        title: I18N.PluginUninstallConfirm(namespace),
        text: I18N.PluginUninstallDesc,
        icon: "warning",
        showCancelButton: true,
        confirmButtonText: I18N.PluginUninstallBtn,
        reverseButtons: true,
        confirmButtonColor: "#d33",
    }).then((result) => {
        if (result.isConfirmed) {
            Server.callAPI(`/api/plugins/installed/${namespace}`, "DELETE",
                I18N.PluginUninstalled, I18N.PluginUninstallError,
                () => { window.location.reload(); },
            );
        }
    });
};

jQuery(() => {
    Plugins.initializeAll();
});
