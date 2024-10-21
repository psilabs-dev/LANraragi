---
description: Everything dealing with Archives.
---

# Archive API

## Get all Archives

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives`

Get the Archive Index in JSON form. You can use the IDs of this JSON with the other endpoints.

{% tabs %}
{% tab title="200 " %}
```javascript
[{
    "arcid": "ec9b83b6a835771b0f9862d0326add2f8373989a",
    "isnew": "true",
    "extension": "zip",
    "pagecount": 128,
    "progress": 0,
    "tags": "",
    "lastreadtime": 1589038280,
    "title": "Ghost in the Shell 01.5 - Human-Error Processor v01c01"
}, {
    "arcid": "28697b96f0ac5858be2614ed10ca47742c9522fd",
    "isnew": "false",
    "extension": "rar",
    "pagecount": 34,
    "progress": 3,
    "tags": "parody:fate grand order,  group:wadamemo,  artist:wada rco,  artbook,  full color",
    "lastreadtime": 1337038281,
    "title": "Fate GO MEMO"
}, {
    "arcid": "2810d5e0a8d027ecefebca6237031a0fa7b91eb3",
    "isnew": "false",
    "extension": "cbz",
    "pagecount": 0,
    "progress": 0,
    "tags": "parody:fate grand order,  character:abigail williams,  character:artoria pendragon alter,  character:asterios,  character:ereshkigal,  character:gilgamesh,  character:hans christian andersen,  character:hassan of serenity,  character:hector,  character:helena blavatsky,  character:irisviel von einzbern,  character:jeanne alter,  character:jeanne darc,  character:kiara sessyoin,  character:kiyohime,  character:lancer,  character:martha,  character:minamoto no raikou,  character:mochizuki chiyome,  character:mordred pendragon,  character:nitocris,  character:oda nobunaga,  character:osakabehime,  character:penthesilea,  character:queen of sheba,  character:rin tosaka,  character:saber,  character:sakata kintoki,  character:scheherazade,  character:sherlock holmes,  character:suzuka gozen,  character:tamamo no mae,  character:ushiwakamaru,  character:waver velvet,  character:xuanzang,  character:zhuge liang,  group:wadamemo,  artist:wada rco,  artbook,  full color",
    "lastreadtime": 1337038282,
    "title": "Fate GO MEMO 2"
}, {
    "arcid": "e69e43e1355267f7d32a4f9b7f2fe108d2401ebf",
    "isnew": "false",
    "extension": "pdf",
    "pagecount": 0,
    "progress": 0,
    "tags": "character:segata sanshiro",
    "lastreadtime": 1337038234,
    "title": "Saturn Backup Cartridge - Japanese Manual"
}, {
    "arcid": "e4c422fd10943dc169e3489a38cdbf57101a5f7e",
    "isnew": "false",
    "extension": "epub",
    "pagecount": 0,
    "progress": 0,
    "tags": "parody: jojo's bizarre adventure",
    "lastreadtime": 0,
    "title": "Rohan Kishibe goes to Gucci"
}]
```
{% endtab %}
{% endtabs %}

## Get Untagged Archives

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives/untagged`

Get archives that don't have any tags recorded. This follows the same rules as the Batch Tagging filter and will include archives that have parody:, date\_added:, series: or artist: tags.

{% tabs %}
{% tab title="200 " %}
```javascript
[
    "d1858d5dc36925aa66be072a97817650d39de166",
    "c3458d5dc36925da93be072a97817650d39de166",
    "28697b96f0ac5858be2614ed10ca47742c9522fd",
]
```
{% endtab %}
{% endtabs %}

## Get Archive Metadata

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives/:id/metadata`

Get Metadata (title, tags) for a given Archive.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

{% tabs %}
{% tab title="200 " %}
```javascript
{
    "arcid": "e69e43e1355267f7d32a4f9b7f2fe108d2401ebf",
    "isnew": "false",
    "pagecount": 34,
    "progress": 3,
    "tags": "character:segata sanshiro",
    "lastreadtime": 1337038234,
    "title": "Saturn Backup Cartridge - Japanese Manual"
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "______",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## Get Archive Categories

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives/:id/categories`

Get all the Categories which currently refer to this Archive ID.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

{% tabs %}
{% tab title="200 " %}
```javascript
{
    "categories": [
        {
            "archives": [
                "0d50858d727723d856d2ab78564bb8e906e65f14",
                "7f03b8b1f337e1e42b2c2890533c0de7479d41ca"
            ],
            "id": "SET_1613080290",
            "name": "My great category",
            "pinned": "0",
            "search": ""
        }
    ],
    "operation": "find_arc_categories",
    "success": 1
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "______",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## Get Archive Tankoubons

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives/:id/tankoubons`

Get all the Tankoubons which currently refer to this Archive ID.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

{% tabs %}
{% tab title="200 " %}
```javascript
{
    "operation": "find_arc_tankoubons",
    "success": 1,
    "tankoubons": [
        "TANK_1688616437",
        "TANK_1688693913"
    ]
}
```
{% endtab %}
{% endtabs %}

## Get Archive Thumbnail

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives/:id/thumbnail`

Get a Thumbnail image for a given Archive. This endpoint will return a placeholder image if it doesn't already exist.\
If you want to queue generation of the thumbnail in the background, you can use the `no_fallback` query parameter. This will give you a background job ID instead of the placeholder.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

#### Query Parameters

| Name         | Type    | Description                                                                                                                                                                                                                    |
| ------------ | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| page         | int     | Specify which page you want to get a thumbnail for. Defaults to the cover, aka page 1.                                                                                                                                         |
| no\_fallback | boolean | <p>Disables the placeholder image, queues the thumbnail for extraction and returns a JSON with code 202.<br>This parameter does nothing if the image already exists. (You will get the image with code 200 no matter what)</p> |

{% tabs %}
{% tab title="202 The thumbnail is queued for extraction. Use `/api/minion/:jobid` to track when your thumbnail is ready." %}
```javascript
{
  "job": 2429,
  "operation": "serve_thumbnail",
  "success": 1
}
```
{% endtab %}

{% tab title="200 If the thumbnail was already extracted, you get it directly." %}
{% tabs %}
{% tab title="2810d5e0a8d027ecefebca6237031a0fa7b91eb3.jpg" %}
```
```
{% endtab %}
{% endtabs %}
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "serve_thumbnail",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## Queue extraction of page thumbnails

<mark style="color:green;">`POST`</mark> `http://lrr.tvc-16.science/api/archives/:id/files/thumbnails`

Create thumbnails for every page of a given Archive. This endpoint will queue generation of the thumbnails in the background.\
If all thumbnails are detected as already existing, the call will return HTTP code 200.\
This endpoint can be called multiple times -- If a thumbnailing job is already in progress for the given ID, it'll just give you the ID for that ongoing job.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

#### Query Parameters

| Name  | Type    | Description                                                                 |
| ----- | ------- | --------------------------------------------------------------------------- |
| force | boolean | Whether to force regeneration of all thumbnails even if they already exist. |

{% tabs %}
{% tab title="202 The thumbnails are queued for extraction. You can use `/api/minion/:jobid` to track progress, by looking at `notes->progress` and `notes->pages`." %}
```javascript
{
  "job": 2429,
  "operation": "generate_page_thumbnails",
  "success": 1
}
```
{% endtab %}

{% tab title="200 If the thumbnails were already extracted and force=0." %}
```javascript
{
  "message": "No job queued, all thumbnails already exist.",
  "operation": "generate_page_thumbnails",
  "success": 1
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "generate_page_thumbnails",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## Download an Archive

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives/:id/download`

Download an Archive from the server.

#### Path Parameters

| Name                                 | Type   | Description                    |
| ------------------------------------ | ------ | ------------------------------ |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to download. |

{% tabs %}
{% tab title="200 " %}
{% tabs %}
{% tab title="Archive.zip" %}
```
```
{% endtab %}
{% endtabs %}
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "______",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## Extract an Archive

<mark style="color:blue;">`GET`</mark> `http://lrr.tvc-16.science/api/archives/:id/files`

Get a list of URLs pointing to the images contained in an archive. If necessary, this endpoint also launches a background Minion job to extract the archive so it is ready for reading.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

#### Query Parameters

| Name  | Type | Description                                                                                                                                                                                                |
| ----- | ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| force | bool | <p>Force a full background re-extraction of the Archive.<br>Existing cached files might still be used in subsequent <code>/api/archives/:id/page</code> calls until the Archive is fully re-extracted.</p> |

{% tabs %}
{% tab title="200 You get page URLs, and the ID of the background extract job." %}
```javascript
{
    "job": 561,
    "pages": [".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=00.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=01.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=03.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=04.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=05.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=06.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=07.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=08.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=09.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=20.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=21.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=22.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=23.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=24.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=25.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=26.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=27.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=28.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=29.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=30.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=31.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=32.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=33.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=34.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=35.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=36.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=37.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=38.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=39.jpg",
        ".\/api\/archives\/28697b96f0ac5858be2614ed10ca47742c9522fd\/page&path=40.jpg"
    ]
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "get_file_list",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## Clear Archive New flag

<mark style="color:red;">`DELETE`</mark> `http://lrr.tvc-16.science/api/archives/:id/isnew`

Clears the "New!" flag on an archive.

#### Path Parameters

| Name                                 | Type   | Description                  |
| ------------------------------------ | ------ | ---------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process |

{% tabs %}
{% tab title="200 " %}
```javascript
{
    "id": "f3fc480a97f1afcd81c8e3392a3bcc66fe6c0809",
    "operation": "clear_new",
    "success": 1
}
```
{% endtab %}
{% endtabs %}

## Update Reading Progression

<mark style="color:orange;">`PUT`</mark> `http://lrr.tvc-16.science/api/archives/:id/progress/:page`

Tell the server which page of this Archive you're currently showing/reading, so that it updates its internal reading progression accordingly.\
This endpoint will also update the date this Archive was last read, using the current server timestamp.

You should call this endpoint only when you're sure the user is currently reading the page you present.\
**Don't** use it when preloading images off the server.

Whether to make reading progression regressible or not is up to the client. (The web client will reduce progression if the user starts reading previous pages)\
Consider however removing the "New!" flag from an archive when you start updating its progress - The web client won't display any reading progression if the new flag is still set.

⚠ If the server is configured to use clientside progress tracking, this API call will return an error!\
Make sure to check using `/api/info` whether the server tracks reading progression or not before calling this endpoint.

#### Path Parameters

| Name                                   | Type   | Description                                                                                                                                    |
| -------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| id<mark style="color:red;">\*</mark>   | string | ID of the Archive to process                                                                                                                   |
| page<mark style="color:red;">\*</mark> | int    | Current page to update the reading progress to. **Must** be a positive integer, and inferior or equal to the total page number of the archive. |

{% tabs %}
{% tab title="200 " %}
```javascript
{
  "id": "75d18ce470dc99f83dc355bdad66319d1f33c82b",
  "operation": "update_progress",
  "page": 34,
  "lastreadtime": 123943543,
  "success": 1
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "update_progress",
    "error": "No archive ID specified.",
    "success": 0
}

{
    "operation": "update_progress",
    "error": "Server-side Progress Tracking is disabled on this instance.",
    "success": 0
}

{
    "operation": "update_progress",
    "error": "Invalid progress value.",
    "success": 0
}

{
    "operation": "update_progress",
    "error": "Archive doesn't have a total page count recorded yet.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## 🔑Upload Archive

<mark style="color:orange;">`PUT`</mark> `http://lrr.tvc-16.science/api/archives/upload`

Upload an Archive to the server.

If a SHA1 checksum of the Archive is included, the server will perform an optional in-transit, file integrity validation, and reject the upload if the server-side checksum does not match.

#### File Parameters

| Name                                           | Type   | Description                                |
| ---------------------------------------------- | ------ | ------------------------------------------ |
| file\_name<mark style="color:red;">\*</mark>   | string | File name of the Archive in the server.    |
| file\_binary<mark style="color:red;">\*</mark> | binary | Data of the Archive represented in binary. |
| upload\_mime                                   | string | MIME type of the Archive.                  |

#### Data Parameters

| Name           | Type   | Description                   |
| -------------- | ------ | ----------------------------- |
| title          | string | Title of the Archive.         |
| tags           | string | Tags of the Archive.          |
| summary        | string | Summary of the Archive.       |
| category\_id   | int    | Category ID of the Archive.   |
| file\_checksum | string | SHA1 checksum of the Archive. |

{% tabs %}
{% tab title="200" %}
```javascript
{
  "operation": "upload",
  "success": 1,
  "id": "7ffb78b32abfb679e4824db9f1e3addf335d0f70"
}
```
{% endtab %}

{% tab title="400" %}
```javascript
{
    "operation": "upload",
    "success": 0,
    "error": "No file attached."
}
```
{% endtab %}

{% tab title="409 duplicate archive" %}
```
{
    "operation": "upload",
    "success": 0,
    "error": "Enable replace duplicated archive in config to replace old ones."
}
```
{% endtab %}

{% tab title="415 unsupported file" %}
```
{
    "operation": "upload",
    "success": 0,
    "error": "Unsupported File Extension (Spirited Away.mkv)"
}
```
{% endtab %}

{% tab title="422 checksum mismatch" %}
```
{
    "operation": "upload",
    "success": 0,
    "error": "Checksum mismatch: expected 92cfceb39d57d914ed8b14d0e37643de0797ae56, got 0286dd552c9bea9a69ecb3759e7b94777635514b."
}
```
{% endtab %}

{% tab title="500" %}
```
{
    "operation": "upload",
    "success": 0,
    "error": "Couldn't move uploaded file."
}
```
{% endtab %}
{% endtabs %}

## 🔑Update Thumbnail

<mark style="color:orange;">`PUT`</mark> `http://lrr.tvc-16.science/api/archives/:id/thumbnail`

Update the cover thumbnail for the given Archive. You can specify a page number to use as the thumbnail, or you can use the default thumbnail.

#### Path Parameters

| Name                                 | Type   | Description                                                |
| ------------------------------------ | ------ | ---------------------------------------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process.                              |
| page                                 | int    | Page you want to make the thumbnail out of. Defaults to 1. |

{% tabs %}
{% tab title="200 " %}
```javascript
{
  "operation": "update_thumbnail",
  "success": 1,
  "new_thumbnail": "/mnt//lrr/content/thumb/95/9595845d952e8141feeba375767248b960979bc2.jpg"
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "update_thumbnail",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## 🔑Update Archive Metadata

<mark style="color:orange;">`PUT`</mark> `http://lrr.tvc-16.science/api/archives/:id/metadata`

Update tags and title for the given Archive. Data supplied to the server through this method will **overwrite** the previous data.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

#### Query Parameters

| Name    | Type   | Description                 |
| ------- | ------ | --------------------------- |
| title   | string | New Title of the Archive.   |
| tags    | string | New Tags of the Archive.    |
| summary | string | New Summary of the Archive. |

{% tabs %}
{% tab title="200 " %}
```javascript
{
    "operation": "update_metadata",
    "success": 1
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "______",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}

## 🔑Delete Archive

<mark style="color:red;">`DELETE`</mark> `http://lrr.tvc-16.science/api/archives/:id`

Delete both the archive metadata and the file stored on the server.\
🙏 Please ask your user for confirmation before invoking this endpoint.

#### Path Parameters

| Name                                 | Type   | Description                   |
| ------------------------------------ | ------ | ----------------------------- |
| id<mark style="color:red;">\*</mark> | string | ID of the Archive to process. |

{% tabs %}
{% tab title="200 " %}
```javascript
{
    "operation": "delete_archive",
    "success": 1,
    "id": "75d18ce470dc99f83dc355bdad66319d1f33c82b",
    "filename": "big_chungus.zip"
}
```
{% endtab %}

{% tab title="400 " %}
```javascript
{
    "operation": "delete_archive",
    "error": "No archive ID specified.",
    "success": 0
}
```
{% endtab %}
{% endtabs %}
