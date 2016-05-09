'use strict';

var frisby = require('frisby');

frisby.create('Root list')
    .get('http://localhost:8000/lists/root')
    .expectStatus(200)
    .expectHeaderContains('content-type', 'application/json')
    .expectJSON({
        id: 'root',
        title: 'Root',
        type: 'directory'
    })
    .expectJSONTypes({
        refreshed: Number,
        items: Array
    })
    .toss();
