const express = require('express');
const async = require('async');
const { Pool } = require('pg');
const cookieParser = require('cookie-parser');
const path = require('node:path');
const app = express();
const server = require('node:http').Server(app);
const io = require('socket.io')(server, { path: '/result/socket.io' });

const port = process.env.PORT || 4000;

// Create two namespaces: root ("/") and "/result"
const rootNamespace = io.of('/');      // Default namespace for pages at "/"
const resultNamespace = io.of('/result'); // Namespace for pages at "/result"

// Handle connections on the default namespace
rootNamespace.on('connection', function (socket) {
  console.log("Connected on root namespace");
  socket.emit('message', { text: 'Welcome from root!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// Handle connections on the /result namespace
resultNamespace.on('connection', function (socket) {
  console.log("Connected on /result namespace");
  socket.emit('message', { text: 'Welcome from result!' });

  socket.on('subscribe', function (data) {
    socket.join(data.channel);
  });
});

// --- Example PostgreSQL logic (adjust as needed) ---
const pgHost = process.env.PG_HOST || 'db';
const pgPort = process.env.PG_PORT || 5432;
const pgUser = process.env.PG_USER || 'postgres';
const pgPassword = process.env.PG_PASSWORD || 'postgres';
const pgDatabase = process.env.PG_DATABASE || 'postgres';

const connectionString = process.env.DATABASE_CONNECTION_STRING
  || process.env.CONNECTION_STRING
  || `postgresql://${pgUser}:${pgPassword}@${pgHost}:${pgPort}/${pgDatabase}`;

const useSsl = process.env.PG_SSL === 'true'
  || (process.env.DATABASE_CONNECTION_STRING || '').includes('sslmode=')
  || (process.env.CONNECTION_STRING || '').includes('sslmode=');

console.log('Using PostgreSQL connection string:', connectionString);

const pool = new Pool({
  connectionString,
  ssl: useSsl ? { rejectUnauthorized: false } : false
});

async.retry(
  { times: 1000, interval: 1000 },
  function (callback) {
    pool.connect(function (err, client, done) {
      if (err) {
        console.error("Waiting for db");
      }
      callback(err, client);
    });
  },
  function (err, client) {
    if (err) {
      return console.error("Giving up");
    }
    console.log("Connected to db");
    getVotes(client);
  }
);

function getVotes(client) {
  client.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote', [], function (err, result) {
    if (err) {
      console.error("Error performing query: " + err);
    } else {
      const votes = collectVotesFromResult(result);

      // Broadcast to both namespaces
      rootNamespace.emit("scores", JSON.stringify(votes));
      resultNamespace.emit("scores", JSON.stringify(votes));
    }

    // Repeat periodically
    setTimeout(function () { getVotes(client); }, 1000);
  });
}

function collectVotesFromResult(result) {
  const votes = { a: 0, b: 0 };
  result.rows.forEach(function (row) {
    votes[row.vote] = Number.parseInt(row.count, 10);
  });
  return votes;
}
// --- End DB example ---

// Basic middleware
app.use(cookieParser());
app.use(express.urlencoded({ extended: true }));

// Serve static files from the "views" folder on both "/" and "/result"
app.use(express.static(path.join(__dirname, 'views')));
app.use("/result", express.static(path.join(__dirname, 'views')));

// Serve the same index.html for both routes
app.get(['/', '/result'], function (req, res) {
  res.sendFile(path.resolve(__dirname, 'views', 'index.html'));
});

// Start server
server.listen(port, function () {
  console.log('App running on port ' + server.address().port);
});
