'use strict';

var frisby = require('frisby');
var savedPlaylist = require('/tmp/playlist.json');
var host = process.env['host'] || 'http://localhost:8000';
var url = host + '/lists/' + savedPlaylist.id;

frisby.create('Playlist exists after restart, trigger media scan')
    .get(url)
    .expectStatus(200)
    .toss();

frisby.create('Playlist equals to saved playlist')
    // let backend scan media files
    .waits(4000)
    .get(url)
    .expectStatus(200)
    .expectHeader('content-type', 'application/json')
    .expectJSON({
        id: savedPlaylist.id,
        editable: savedPlaylist.editable,
        title: savedPlaylist.title,
        type: savedPlaylist.type
    })
    .expectJSONTypes({
        refreshed: Number
    })
    .afterJSON(function(playlistJson) {
        // test equality of media files
        for (var i = 0; i < playlistJson.items.length; i++) {
            console.log(playlistJson.items[i], savedPlaylist.items[i]);
            expect(playlistJson.items[i].id).toEqual(savedPlaylist.items[i].id);
            expect(playlistJson.items[i].title).toEqual(savedPlaylist.items[i].title);
            expect(playlistJson.items[i].type).toEqual(savedPlaylist.items[i].type);
        }
    })
    .toss();

frisby.create('Remove created playlist')
    .delete(url)
    .expectStatus(200)
    .toss();
