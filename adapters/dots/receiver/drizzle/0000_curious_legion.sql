CREATE TABLE `dots_deliveries` (
	`id` text PRIMARY KEY NOT NULL,
	`digest` text NOT NULL,
	`body` text,
	`attention` text NOT NULL,
	`acknowledged` integer DEFAULT 0 NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`next_attempt` integer DEFAULT 0 NOT NULL,
	`callback_received` integer DEFAULT 0 NOT NULL
);
--> statement-breakpoint
CREATE TABLE `dots_endpoint` (
	`ship` text PRIMARY KEY NOT NULL,
	`owner` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `dots_subscriptions` (
	`id` text PRIMARY KEY NOT NULL,
	`attention` text NOT NULL,
	`url` text NOT NULL,
	`secret` text,
	`old_secret` text,
	`old_until` integer,
	`expires` integer DEFAULT 0 NOT NULL,
	`revision` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `dots_subscriptions_attention_unique` ON `dots_subscriptions` (`attention`);