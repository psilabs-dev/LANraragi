

const Integrations = {};
Integrations.queueDownloadButtonValue = null;
Integrations.downloadServerRunning = false;
Integrations.checkedDownloadServerStatus = false;

/**
 * Initialize button behavior.
 */
Integrations.initialize = function () {
    console.log("Initialized integrations.");
    $(document).on("click.queue-download-pixiv-by-user-id", "#queue-download-pixiv-by-user-id", () => {
        console.log("Queueing Pixiv user ID download by value: ", Integrations.queueDownloadButtonValue);

        const endpoint = new LRR.apiURL(`/api/integrations/pixiv/download_by_member/${Integrations.queueDownloadButtonValue}`);
        fetch(endpoint, { method: "POST" })
            .then(async (response) => {
                if (response.ok) {
                    LRR.toast({
                        heading: `Queued artwork downloads by Pixiv user ID: ${Integrations.queueDownloadButtonValue}`,
                        icon: "success",
                    });
                    return;
                }
                const json = await response.json();
                LRR.showErrorToast(`Download Failed! (HTTP ${response.status})`, json.error);
            })
            .catch((err) => LRR.showErrorToast("Network error", String(err)));

    });
    $(document).on("click.queue-download-twitter-by-user-id", "#queue-download-twitter-by-user-id", () => {
        console.log("Queueing Twitter user ID download by value: ", Integrations.queueDownloadButtonValue);

        const endpoint = new LRR.apiURL(`/api/integrations/twitterdl/download_by_user_id/${Integrations.queueDownloadButtonValue}`);
        fetch(endpoint, { method: "POST" })
            .then(async (response) => {
                if (response.ok) {
                    LRR.toast({
                        heading: `Queued artwork downloads by Twitter user ID: ${Integrations.queueDownloadButtonValue}`,
                        icon: "success",
                    });
                    return;
                }
                const json = await response.json();
                LRR.showErrorToast(`Download Failed! (HTTP ${response.status})`, json.error);
            })
            .catch((err) => LRR.showErrorToast("Network error", String(err)));
    });
}

/**
 * Update search options based on search filter.
 * If tag is namespaced, and namespace is pixiv/twitter user ID,
 * adds a button to queue a download in the server for the user's content.
 */
Integrations.updateSearchOptions = function () {
    const searchInput = $("#search-input").val();
    console.log("Updating integrations with search filter: ", searchInput);

    // skip composite search options.
    if (searchInput.includes(',')) {
        $('#queue-download-pixiv-by-user-id').remove();
        $('#queue-download-twitter-by-user-id').remove();
        console.log("Skip (has comment)");
        return;
    }

    // skip non-namespace options.
    if (!searchInput.includes(':')) {
        $('#queue-download-pixiv-by-user-id').remove();
        $('#queue-download-twitter-by-user-id').remove();
        console.log("Skip (no colon)");
        return;
    }

    const parts = searchInput.split(/:(.+)/);
    const namespace = String(parts[0]).trim().toLowerCase();
    const value = String(parts[1]).trim();
    Integrations.queueDownloadButtonValue = value;
    
    console.log("Namespace is: ", namespace);
    if ($('#queue-download-pixiv-by-user-id').length) {
        $('#queue-download-pixiv-by-user-id').remove();
        console.log("Remove existing pixiv button.");
    }
    if ($('#queue-download-twitter-by-user-id').length) {
        $('#queue-download-twitter-by-user-id').remove();
        console.log("Remove existing twitter button.");
    }

    if (!LRR.isUserLogged()) {
        console.log("Not logged in.");
        return;
    }

    if (namespace == 'pixiv_user_id') {
        if (!Integrations.checkedDownloadServerStatus) {
            const pixiv_endpoint = new LRR.apiURL(`/api/integrations/pixiv/status`);
            Integrations.downloadServerRunning = fetch(pixiv_endpoint, { method: "GET" })
            .then(async (response) => {
                if (response.ok) {
                    console.log("Response is OK.");
                    return true;
                }
                console.log("Response not OK.");
                return false;
            });
        }
        if (!Integrations.downloadServerRunning) {
            console.log("Skip (pdl server not running)");
            return;
        }
        console.log("Applying Pixiv download button.");
        $('<input>', {
            id: 'queue-download-pixiv-by-user-id',
            class: 'searchbtn stdbtn',
            type: 'button',
            value: 'Queue Download'
        }).insertAfter('#clear-search')

    } else if (namespace == 'twitter_user_id') {
        if (!Integrations.checkedDownloadServerStatus) {
            const twitterdl_endpoint = new LRR.apiURL(`/api/integrations/twitterdl/status`);
            Integrations.downloadServerRunning = fetch(twitterdl_endpoint, { method: "GET" })
            .then(async (response) => {
                if (response.ok) {
                    console.log("Response is OK.");
                    return true;
                }
                console.log("Response not OK.");
                return false;
            });
            Integrations.checkedDownloadServerStatus = true;
        }
        if (!Integrations.downloadServerRunning) {
            console.log("Skip (tdl server not running)");
            return;
        }
        console.log("Applying Twitter download button.");
        $('<input>', {
            id: 'queue-download-twitter-by-user-id',
            class: 'searchbtn stdbtn',
            type: 'button',
            value: 'Queue Download'
        }).insertAfter('#clear-search')

    }

}