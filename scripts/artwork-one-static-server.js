#!/usr/bin/env node
'use strict';

/*
 * Minimal static file server for a single-page app (e.g. a build of Artwork One).
 *
 * Written for old Node (v8.11, Volumio 2 / Musical Fidelity MX-Stream): no dependencies,
 * no async/await, no optional chaining. Read-only: GET and HEAD only, files below the
 * served folder only. Paths without a file extension that do not exist fall back to
 * index.html, so reloading or opening a deep link of the app works.
 *
 * Usage:   node artwork-one-static-server.js [folder] [port]
 * Default: folder = /mnt/INTERNAL/artwork-one, port = 8080
 * Stop:    Ctrl-C
 */

var http = require('http');
var fs = require('fs');
var path = require('path');
var url = require('url');

var ROOT = path.resolve(process.argv[2] || '/mnt/INTERNAL/artwork-one');
var PORT = parseInt(process.argv[3] || '8080', 10);

var TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json; charset=utf-8'
};

if (!fs.existsSync(path.join(ROOT, 'index.html'))) {
  console.error('error: ' + path.join(ROOT, 'index.html') + ' not found (is this the dist/ folder of the build?)');
  process.exit(1);
}

function send(res, status, text) {
  res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end(text);
}

function serveFile(req, res, file, stat) {
  var type = TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream';
  var headers = { 'Content-Type': type, 'Content-Length': stat.size, 'Last-Modified': stat.mtime.toUTCString() };
  // index.html must always be fetched fresh; hashed assets may be cached
  headers['Cache-Control'] = path.basename(file) === 'index.html' ? 'no-cache' : 'public, max-age=3600';
  res.writeHead(200, headers);
  if (req.method === 'HEAD') { res.end(); return; }
  var stream = fs.createReadStream(file);
  stream.on('error', function () { res.destroy(); });
  stream.pipe(res);
}

var server = http.createServer(function (req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') { return send(res, 405, 'Method not allowed'); }

  var pathname;
  try { pathname = decodeURIComponent(url.parse(req.url).pathname || '/'); } catch (e) { return send(res, 400, 'Bad request'); }
  if (pathname.indexOf('\0') !== -1) { return send(res, 400, 'Bad request'); }

  var file = path.join(ROOT, path.normalize(pathname));
  // never leave the served folder
  if (file !== ROOT && file.indexOf(ROOT + path.sep) !== 0) { return send(res, 403, 'Forbidden'); }

  fs.stat(file, function (err, stat) {
    if (!err && stat.isDirectory()) {
      file = path.join(file, 'index.html');
      return fs.stat(file, function (err2, stat2) {
        if (err2 || !stat2.isFile()) { return send(res, 404, 'Not found'); }
        serveFile(req, res, file, stat2);
      });
    }
    if (!err && stat.isFile()) { return serveFile(req, res, file, stat); }

    // a missing file with an extension is a real 404; a missing route falls back to the app
    if (path.extname(pathname)) { return send(res, 404, 'Not found'); }
    var index = path.join(ROOT, 'index.html');
    fs.stat(index, function (err3, stat3) {
      if (err3 || !stat3.isFile()) { return send(res, 404, 'Not found'); }
      serveFile(req, res, index, stat3);
    });
  });
});

server.on('error', function (e) {
  console.error('error: ' + e.message);
  process.exit(1);
});

server.listen(PORT, function () {
  console.log('serving ' + ROOT + ' on port ' + PORT + ' (Ctrl-C to stop)');
});
