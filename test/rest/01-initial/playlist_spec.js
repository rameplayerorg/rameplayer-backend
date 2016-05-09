'use strict';

var frisby = require('frisby');
var fs = require('fs');

var host = process.env['host'] || 'http://localhost:8000';
var playlistTitle = 'Frisby test';

// file is used in after_restart/playlist_spec.js
var savedPlaylistFile = '/tmp/playlist.json';

// first, read rame list
frisby.create('Rame list')
    .get(host + '/lists/rame')
    .afterJSON(function(rameJson) {
        // open internal list
        var internalId = rameJson.items[0].id;
        frisby.create('Read internal list first time, triggering media scanning')
            .get(host + '/lists/' + internalId)
            .expectStatus(200)
            .toss();

        frisby.create('Parse internal list')
            .get(host + '/lists/' + internalId)
            .waits(3000)
            .expectStatus(200)
            .expectHeader('content-type', 'application/json')
            // expect that 3 videos are found from this list
            .expectJSON('items.?', {
                name: 'blue_screen.mp4',
                title: 'Blüe Screen',
                duration: 3,
            })
            .expectJSON('items.?', {
                name: 'green_screen.mp4',
                title: 'Green Screen',
                duration: 2,
            })
            .expectJSON('items.?', {
                name: 'red_screen.mp4',
                title: 'Red Screen',
                duration: 4,
            })
            //.inspectJSON()
            .afterJSON(function(internalJson) {
                var items = getPlaylistItems(internalJson);
                frisby.create('Create playlist')
                    .post(host + '/lists/', {
                        items: items,
                        storage: 'rame',
                        title: playlistTitle
                    }, {
                        json: true
                    })
                    .expectStatus(200)
                    .expectJSONTypes({
                        refreshed: Number,
                        id: String
                    })
                    .expectJSON({
                        title: playlistTitle,
                        type: 'playlist'
                    })
                    //.inspectJSON()
                    .afterJSON(function(createJson) {
                        frisby.create('Read created playlist')
                            // let backend scan media files
                            .get(host + '/lists/' + createJson.id)
                            .expectStatus(200)
                            .expectHeader('content-type', 'application/json')
                            .expectJSON({
                                editable: true,
                                title: playlistTitle,
                                type: 'playlist'
                            })
                            .expectJSONTypes({
                                id: String,
                                refreshed: Number
                            })
                            .expectJSON('items.?', {
                                name: 'blue_screen.mp4',
                                type: 'regular'
                            })
                            .expectJSON('items.?', {
                                name: 'green_screen.mp4',
                                type: 'regular'
                            })
                            .expectJSON('items.?', {
                                name: 'red_screen.mp4',
                                type: 'regular'
                            })
                            //.inspectJSON()
                            .afterJSON(function(playlistJson) {
                                fs.writeFile(savedPlaylistFile, JSON.stringify(playlistJson));
                            })
                            .toss();
                    })
                    .toss();
            })
            .toss();
    })
    .toss();

function getPlaylistItems(json) {
    var items = [];
    for (var i = 0; i < json.items.length; i++) {
        items.push({
            uri: json.items[i].uri,
            title: json.items[i].title
        });
    }
    return items;
}
