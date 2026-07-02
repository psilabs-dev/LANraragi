/**
 * Config Operations
 */
import * as Server from "./mod/server.js";
import * as LRR from "./mod/common.js";
import I18N from "i18n";

const Config = {};

Config.initializeAll = function () {
    // bind events to DOM
    $(document).on("click.save", "#save", () => { Server.saveFormData("#editConfigForm"); });
    $(document).on("click.plugin-config", "#plugin-config", () => { window.location.href = new LRR.ApiURL("/config/plugins"); });
    $(document).on("click.backup", "#backup", () => { window.location.href = new LRR.ApiURL("/backup"); });
    $(document).on("click.batch", "#batch", () => { window.location.href = new LRR.ApiURL("/batch"); });
    $(document).on("click.return", "#return", () => { window.location.href = new LRR.ApiURL("/"); });
    $(document).on("click.enablepass", "#enablepass", Config.enable_pass);
    $(document).on("click.enableresize", "#enableresize", Config.enable_resize);
    $(document).on("click.usedateadded", "#usedateadded", Config.enable_timemodified);

    $(document).on("click.rescan-button", "#rescan-button", Config.rescanContentFolder);
    $(document).on("click.clean-temp", "#clean-temp", Server.cleanTemporaryFolder);
    $(document).on("click.reset-search-cache", "#reset-search-cache", Server.invalidateCache);
    $(document).on("click.clear-new-tags", "#clear-new-tags", Server.clearAllNewFlags);

    $(document).on("click.clean-db", "#clean-db", Server.cleanDatabase);
    $(document).on("click.drop-db", "#drop-db", Server.dropDatabase);

    $(document).on("click.restart-button", "#restart-button", Config.rebootShinobu);
    $(document).on("click.open-minion", "#open-minion", () => LRR.openInNewTab(new LRR.ApiURL("/minion")));

    $(document).on("click.genthumb-button", "#genthumb-button", () => Server.regenerateThumbnails(false));
    $(document).on("click.forcethumb-button", "#forcethumb-button", () => Server.regenerateThumbnails(true));

    $(document).on("click.theme-switch", ".theme-switch", Config.switchStyle);

    // Registry events
    $(document).on("click.registry-edit", "#registry-edit-btn", Config.registryShowForm);
    $(document).on("click.registry-remove", "#registry-remove-btn", Config.registryRemove);
    $(document).on("click.registry-save", "#registry-save-btn", Config.registrySave);
    $(document).on("click.registry-cancel", "#registry-cancel-btn", Config.registryLoad);
    $(document).on("change.reg-provider", "#reg-provider", Config.registryToggleProviderFields);

    Config.enable_pass();
    Config.enable_resize();
    Config.enable_timemodified();
    Config.shinobuStatus();
    setInterval(Config.shinobuStatus, 5000);
    Config.registryLoad();
};

Config.rebootShinobu = function () {
    $("#restart-button").prop("disabled", true);
    Server.callAPI("/api/shinobu/restart", "POST", I18N.ShinobuRestarted, I18N.ShinobuRestartError,
        () => {
            $("#restart-button").prop("disabled", false);
            Config.shinobuStatus();
        },
    );
};

Config.rescanContentFolder = function () {
    $("#rescan-button").prop("disabled", true);
    Server.callAPI("/api/shinobu/rescan", "POST", I18N.ContentRescanStarted, I18N.ContentRescanError,
        () => {
            $("#rescan-button").prop("disabled", false);
            Config.shinobuStatus();
        },
    );
};

// Update the status of the background worker.
Config.shinobuStatus = function () {
    Server.callAPI("/api/shinobu", "GET", null, I18N.ShinobuStatusError,
        (data) => {
            if (data.is_alive) {
                $("#shinobu-ok").show();
                $("#shinobu-ko").hide();
            } else {
                $("#shinobu-ko").show();
                $("#shinobu-ok").hide();
            }
            $("#pid").html(data.pid);
        },
    );
};

Config.switchStyle = function (e) {
    let i, linkTag, correctStyle, defaultStyle, newStyle;
    correctStyle = 0;

    const cssTitle = e.currentTarget.title;

    for (i = 0, linkTag = document.getElementsByTagName("link"); i < linkTag.length; i++) {
        if ((linkTag[i].rel.indexOf("stylesheet") !== -1) && linkTag[i].title) {
            if ((linkTag[i].rel.indexOf("alternate stylesheet") !== -1)) 
                linkTag[i].disabled = true;
            else 
                defaultStyle = linkTag[i];

            if (linkTag[i].title === cssTitle) {
                newStyle = linkTag[i];
                correctStyle = 1;
            }
        }
    }

    if (correctStyle === 1) { // if the style that was switched to exists
        defaultStyle.disabled = true; // we disable the default style
        newStyle.disabled = false; // we enable the new style
    }
};

Config.enable_pass = function () {
    if ($("#enablepass").prop("checked")) $(".passwordfields").show();
    else $(".passwordfields").hide();
};

Config.enable_resize = function () {
    if ($("#enableresize").prop("checked")) $(".resizefields").show();
    else $(".resizefields").hide();
};

Config.enable_timemodified = function () {
    if ($("#usedateadded").prop("checked")) $(".datemodified").show();
    else $(".datemodified").hide();
};

// Currently loaded registry ID (null if none)
Config.registryId = null;

Config.registryToggleProviderFields = function () {
    const provider = $("#reg-provider").val();
    if (provider === "local") {
        $(".reg-url-fields").hide();
        $(".reg-git-ref-fields").hide();
        $(".reg-local-fields").show();
    } else if (provider === "cdn") {
        $(".reg-url-fields").show();
        $(".reg-git-ref-fields").hide();
        $(".reg-local-fields").hide();
    } else {
        $(".reg-url-fields").show();
        $(".reg-git-ref-fields").show();
        $(".reg-local-fields").hide();
    }
};

Config.registryLoad = function () {
    Server.callAPI("/api/registries", "GET", null, "Failed to load registries",
        (data) => {
            const { registries } = data;

            if (registries.length === 0) {
                Config.registryId = null;
                $("#registry-view").hide();
                $(".registry-form").hide();
                $("#registry-none").show();
                // Show form for adding
                Config.registryShowForm();
            } else {
                const reg = registries[0];
                Config.registryId = reg.id;

                $("#registry-name").text(reg.name);

                let details = reg.provider;
                if (reg.provider === "local") {
                    details += " — " + reg.path;
                } else {
                    details += " — " + reg.url;
                    if (reg.ref) details += " @ " + reg.ref;
                }
                $("#registry-details").text(details);

                $("#registry-none").hide();
                $(".registry-form").hide();
                $("#registry-view").show();
            }
        },
    );
};

Config.registryShowForm = function () {
    $("#registry-none").hide();
    $("#registry-view").hide();

    // If editing, pre-populate
    if (Config.registryId) {
        Server.callAPI(`/api/registries/${Config.registryId}`, "GET", null, "Failed to load registry",
            (data) => {
                const reg = data.registry;
                $("#reg-name").val(reg.name);
                $("#reg-provider").val(reg.provider);
                if (reg.provider === "local") {
                    $("#reg-path").val(reg.path);
                } else {
                    $("#reg-url").val(reg.url);
                    $("#reg-ref").val(reg.ref || "");
                }
                $(".registry-form").show();
                Config.registryToggleProviderFields();
            },
        );
    } else {
        // Reset form for new registry
        $("#reg-name").val("");
        $("#reg-provider").val("github");
        $("#reg-url").val("");
        $("#reg-ref").val("");
        $("#reg-path").val("");
        $(".registry-form").show();
        Config.registryToggleProviderFields();
    }
};

Config.registrySave = function () {
    const provider = $("#reg-provider").val();
    const body = { name: $("#reg-name").val(), provider };

    if (provider === "local") {
        const path = $("#reg-path").val();
        if (!path) {
            LRR.showErrorToast("Path is required for local registries.", "");
            return;
        }
        body.path = path;
    } else if (provider === "cdn") {
        const url = $("#reg-url").val();
        if (!url) {
            LRR.showErrorToast("Repository URL is required.", "");
            return;
        }
        body.url = url;
    } else {
        const url = $("#reg-url").val();
        const ref = $("#reg-ref").val();
        if (!url) {
            LRR.showErrorToast("Repository URL is required.", "");
            return;
        }
        if (!ref) {
            LRR.showErrorToast("Git ref is required for github/gitlab/gitea registries.", "");
            return;
        }
        body.url = url;
        body.ref = ref;
    }

    if (Config.registryId) {
        // Update existing
        Server.callAPIJSON(`/api/registries/${Config.registryId}`, "PUT", body,
            "Registry updated.", "Failed to update registry",
            () => Config.registryLoad(),
        );
    } else {
        // Create new
        Server.callAPIJSON("/api/registries", "POST", body,
            "Registry added.", "Failed to add registry",
            () => Config.registryLoad(),
        );
    }
};

Config.registryRemove = function () {
    LRR.showPopUp({
        title: "Remove this registry?",
        text: "Installed plugins will not be removed.",
        icon: "warning",
        showCancelButton: true,
        confirmButtonText: "Remove",
        reverseButtons: true,
        confirmButtonColor: "#d33",
    }).then((result) => {
        if (result.isConfirmed) {
            Server.callAPI(`/api/registries/${Config.registryId}`, "DELETE",
                "Registry removed.", "Failed to remove registry",
                () => Config.registryLoad(),
            );
        }
    });
};

jQuery(() => {
    Config.initializeAll();
});
