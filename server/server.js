const https = require('https');
const express = require('express');
const { Server } = require('socket.io');
const selfsigned = require('selfsigned');
const WebSocket = require('ws');
const path = require('path');
const fs = require('fs');

// ── Self-signed cert ─────────────────────────────────────────────────────────
const CERT_FILE = path.join(__dirname, 'cert.pem');
const KEY_FILE  = path.join(__dirname, 'key.pem');

async function loadOrGenerateCert() {
  if (fs.existsSync(CERT_FILE) && fs.existsSync(KEY_FILE)) {
    return {
      cert: fs.readFileSync(CERT_FILE, 'utf8'),
      key:  fs.readFileSync(KEY_FILE,  'utf8'),
    };
  }
  const attrs = [{ name: 'commonName', value: 'space-pirates.local' }];
  const pems  = await selfsigned.generate(attrs, { days: 365 });
  fs.writeFileSync(CERT_FILE, pems.cert);
  fs.writeFileSync(KEY_FILE,  pems.private);
  console.log('Generated self-signed cert.');
  return { cert: pems.cert, key: pems.private };
}

async function main() {
const { cert: certPem, key: keyPem } = await loadOrGenerateCert();

// ── Express + HTTPS ──────────────────────────────────────────────────────────
const app    = express();
const server = https.createServer({ cert: certPem, key: keyPem }, app);

app.use(express.static(path.join(__dirname, 'public')));
app.get('/pilot', (_req, res) =>
  res.sendFile(path.join(__dirname, 'public', 'pilot.html'))
);

// ── Slot management ──────────────────────────────────────────────────────────
const COLORS   = ['#00f5ff', '#ff3f3f', '#39ff14', '#ff9f00', '#cc44ff'];
const MAX_SLOTS = 5;

// slots[i] = { socketId, color } or null
const slots = Array(MAX_SLOTS).fill(null);

function assignSlot(socketId) {
  const i = slots.findIndex(s => s === null);
  if (i === -1) return null;
  slots[i] = { socketId, color: COLORS[i], shipId: null, ready: false };
  return i;
}

function releaseSlot(socketId) {
  const i = slots.findIndex(s => s && s.socketId === socketId);
  if (i === -1) return null;
  slots[i] = null;
  return i;
}

function slotOf(socketId) {
  return slots.findIndex(s => s && s.socketId === socketId);
}

// ── Godot WebSocket server (plain WS on :4000) ───────────────────────────────
const WS_PORT = 4000;
const wss     = new WebSocket.Server({ port: WS_PORT });
let godotSocket = null;

wss.on('connection', ws => {
  godotSocket = ws;
  console.log('Godot connected on ws://localhost:4000');

  // Send current slot state so Godot can catch up if it reconnects
  slots.forEach((slot, i) => {
    if (slot) {
      sendToGodot({ type: 'pilot_joined', slot: i, color: slot.color });
      if (slot.shipId !== null)
        sendToGodot({ type: 'ship_selected', slot: i, shipId: slot.shipId });
      if (slot.ready)
        sendToGodot({ type: 'pilot_ready', slot: i });
    }
  });

  ws.on('close', () => {
    console.log('Godot disconnected');
    godotSocket = null;
  });

  ws.on('message', raw => {
    // Godot → server messages (e.g. game_start, game_over)
    try {
      const msg = JSON.parse(raw);
      handleGodotMessage(msg);
    } catch (e) {
      console.warn('Bad Godot message:', raw);
    }
  });
});

function sendToGodot(obj) {
  if (godotSocket && godotSocket.readyState === WebSocket.OPEN)
    godotSocket.send(JSON.stringify(obj));
}

function handleGodotMessage(msg) {
  if (msg.type === 'game_start') {
    io.emit('game_start');
  } else if (msg.type === 'game_over') {
    io.emit('game_over', { winnerSlot: msg.winnerSlot });
  } else if (msg.type === 'lobby_reset') {
    io.emit('lobby_reset');
  }
}

// ── Socket.IO (phones) ───────────────────────────────────────────────────────
const io = new Server(server, {
  cors: { origin: '*' }
});

io.on('connection', socket => {
  console.log('Phone connected:', socket.id);

  socket.on('register', role => {
    if (role !== 'pilot') return;

    const i = assignSlot(socket.id);
    if (i === null) {
      socket.emit('error', 'Game is full (5 players max)');
      return;
    }

    console.log(`Slot ${i} assigned to ${socket.id} (${COLORS[i]})`);
    socket.emit('pilot_assigned', { slot: i, color: COLORS[i] });
    sendToGodot({ type: 'pilot_joined', slot: i, color: COLORS[i] });
  });

  socket.on('ship_selected', ({ shipId }) => {
    const i = slotOf(socket.id);
    if (i === -1) return;
    slots[i].shipId = shipId;
    console.log(`Slot ${i} selected ship: ${shipId}`);
    sendToGodot({ type: 'ship_selected', slot: i, shipId });
  });

  socket.on('player_ready', () => {
    const i = slotOf(socket.id);
    if (i === -1) return;
    slots[i].ready = true;
    console.log(`Slot ${i} gyro ready`);
    sendToGodot({ type: 'pilot_ready', slot: i });
  });

  socket.on('pilot_input', data => {
    const i = slotOf(socket.id);
    if (i === -1) return;
    // Relay immediately — volatile for low latency
    sendToGodot({ type: 'input', slot: i, ...data });
  });

  socket.on('lobby_mode_selected', ({ mode, chapter }) => {
    sendToGodot({ type: 'lobby_mode_selected', mode, chapter: chapter ?? -1 });
  });

  socket.on('disconnect', () => {
    const i = releaseSlot(socket.id);
    if (i !== -1 && i !== null) {
      console.log(`Slot ${i} released`);
      sendToGodot({ type: 'pilot_left', slot: i });
    }
  });
});

// ── Start ─────────────────────────────────────────────────────────────────────
const HTTPS_PORT = 3443;
server.listen(HTTPS_PORT, () => {
  const { networkInterfaces } = require('os');
  const nets = networkInterfaces();
  let localIP = 'localhost';
  for (const iface of Object.values(nets)) {
    for (const net of iface) {
      if (net.family === 'IPv4' && !net.internal) { localIP = net.address; break; }
    }
    if (localIP !== 'localhost') break;
  }
  console.log(`\nSpace Pirates server running`);
  console.log(`  Phones  →  https://${localIP}:${HTTPS_PORT}/pilot`);
  console.log(`  Godot   →  ws://localhost:${WS_PORT}\n`);
});

} // end main()
main().catch(err => { console.error(err); process.exit(1); });
