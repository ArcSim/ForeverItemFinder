// For the offline tests only: Node's built-in SQLite dressed as Cloudflare D1 (prepare / bind / first / all / run /
// batch), counting every statement as a query the way a Worker's budget does.
import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';

class Stmt {
  constructor(db, sql, args = []) { this.db = db; this.sql = sql; this.args = args; }
  bind(...args) { return new Stmt(this.db, this.sql, args); }
  async first() { this.db.queries++; return this.db.raw.prepare(this.sql).get(...this.args) ?? null; }
  async all() { this.db.queries++; return { results: this.db.raw.prepare(this.sql).all(...this.args) }; }
  async run() { this.db.queries++; const r = this.db.raw.prepare(this.sql).run(...this.args); return { meta: { changes: Number(r.changes) } }; }
}

export async function openDb(schemaPath) {
  const db = { raw: new DatabaseSync(':memory:'), queries: 0 };
  db.raw.exec(fs.readFileSync(schemaPath, 'utf8'));
  db.prepare = (sql) => new Stmt(db, sql);
  db.batch = async (stmts) => {
    db.raw.exec('BEGIN');
    try {
      const out = [];
      for (const s of stmts) out.push(await s.run());
      db.raw.exec('COMMIT');
      return out;
    } catch (e) {
      db.raw.exec('ROLLBACK');
      throw e;
    }
  };
  return db;
}
