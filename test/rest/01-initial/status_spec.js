'use strict';

var frisby = require('frisby');

var host = process.env['host'] || 'http://localhost:8000';

frisby.create('Status with lists')
    .post(host + '/status', {
        lists: [
            "root",
            "rame"
        ]
    }, {
        json: true
    })
    .expectStatus(200)
    .expectHeaderContains('content-type', 'application/json')
    .expectJSON({
        state: 'stopped',
        position: 0
    })
    .expectJSONTypes({
        listsRefreshed: {
            root: Number,
            rame: Number
        },
        cursor: {
        }
    })
    .toss();

// -----------

frisby.create('Status with cluster')
    .post(host + '/status', {
        cluster: true,
    }, {
        json: true
    })
    .expectStatus(200)
    .expectHeaderContains('content-type', 'application/json')
    .expectJSONTypes({
        cluster: {
            controller: String
        }
    })
    .toss();

// -----------

frisby.create('Status with cluster cleared after 3 seconds')
    .post(host + '/status')
    .waits(3200)
    .expectStatus(200)
    .expectHeaderContains('content-type', 'application/json')
    .expectJSONTypes({
        cluster: function(val) { expect(val).not.toBeDefined(); }
    })
    .toss();
