import http from 'node:http';

const PORT = 3999;

const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', chunk => {
    body += chunk;
  });
  req.on('end', () => {
    let task = '';
    try {
      const parsed = JSON.parse(body);
      const userMsg = Array.isArray(parsed.messages)
        ? parsed.messages.find(m => m.role === 'user')
        : null;
      task = userMsg ? userMsg.content : '';
    } catch {
    }
    const payload = {
      mock: true,
      echo: task.slice(0, 100),
      hint: 'this is a mock AI response for local testing'
    };
    const content = '```json\n' + JSON.stringify(payload) + '\n```';
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content } }] }));
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`mock ai listening on http://127.0.0.1:${PORT}`);
});
