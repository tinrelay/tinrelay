import {sqliteTable, text, integer} from 'drizzle-orm/sqlite-core';
export const endpoint = sqliteTable('dots_endpoint', {
  ship: text('ship').primaryKey(), owner: text('owner').notNull(),
});
export const deliveries = sqliteTable('dots_deliveries', {
  id: text('id').primaryKey(), digest: text('digest').notNull(), body: text('body'),
  attention: text('attention').notNull(), acknowledged: integer('acknowledged').notNull().default(0),
  attempts: integer('attempts').notNull().default(0), nextAttempt: integer('next_attempt').notNull().default(0),
  callbackReceived: integer('callback_received').notNull().default(0),
});
export const subscriptions = sqliteTable('dots_subscriptions', {
  id: text('id').primaryKey(), attention: text('attention').notNull().unique(), url: text('url').notNull(),
  secret: text('secret'), oldSecret: text('old_secret'), oldUntil: integer('old_until'),
  expires: integer('expires').notNull().default(0), revision: text('revision').notNull(),
});
