const fs = require('fs');
const path = require('path');

const DATA_DIR = path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'todos.json');

function exitWithError(message) {
  console.error(message);
  process.exit(1);
}

function ensureDataDir() {
  if (!fs.existsSync(DATA_DIR)) {
    fs.mkdirSync(DATA_DIR, { recursive: true });
  }
}

function loadTodos() {
  ensureDataDir();

  if (!fs.existsSync(DATA_FILE)) {
    return [];
  }

  const content = fs.readFileSync(DATA_FILE, 'utf8').trim();
  if (content === '') {
    return [];
  }

  return JSON.parse(content);
}

function saveTodos(todos) {
  ensureDataDir();
  fs.writeFileSync(DATA_FILE, JSON.stringify(todos, null, 2));
}

function addTodo(title) {
  if (!title || title.trim() === '') {
    exitWithError('Error: title is required');
  }

  const todos = loadTodos();
  const maxId = todos.reduce((currentMax, todo) => Math.max(currentMax, todo.id), 0);
  const todo = {
    id: maxId + 1,
    title: title.trim(),
    done: false,
    createdAt: new Date().toISOString(),
  };

  todos.push(todo);
  saveTodos(todos);
}

function doneTodo(id) {
  const todos = loadTodos();
  const todo = todos.find((item) => item.id === id);

  if (!todo) {
    exitWithError(`Error: ID ${id} not found`);
  }

  todo.done = true;
  saveTodos(todos);
}

function deleteTodo(id) {
  const todos = loadTodos();
  const index = todos.findIndex((item) => item.id === id);

  if (index === -1) {
    exitWithError(`Error: ID ${id} not found`);
  }

  todos.splice(index, 1);
  saveTodos(todos);
}

function listTodos() {
  const todos = loadTodos();

  if (todos.length === 0) {
    console.log('No todos.');
    return;
  }

  todos.forEach((todo) => {
    const mark = todo.done ? 'x' : ' ';
    const date = new Date(todo.createdAt).toISOString().slice(0, 10);
    console.log(`[${todo.id}] [${mark}] ${todo.title}  (${date})`);
  });
}

function parseId(value) {
  const id = Number.parseInt(value, 10);
  if (Number.isNaN(id)) {
    exitWithError(`Error: ID ${value} not found`);
  }
  return id;
}

function main() {
  const [, , command, ...args] = process.argv;

  switch (command) {
    case 'add':
      addTodo(args.join(' '));
      break;
    case 'list':
      listTodos();
      break;
    case 'done':
      doneTodo(parseId(args[0]));
      break;
    case 'delete':
      deleteTodo(parseId(args[0]));
      break;
    default:
      exitWithError('Error: invalid command');
  }
}

main();
