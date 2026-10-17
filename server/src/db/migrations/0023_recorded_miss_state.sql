ALTER TABLE "occurrence_events" DROP CONSTRAINT "occurrence_events_action_check";--> statement-breakpoint
ALTER TABLE "occurrence_events" DROP CONSTRAINT "occurrence_events_from_state_check";--> statement-breakpoint
ALTER TABLE "occurrence_events" DROP CONSTRAINT "occurrence_events_to_state_check";--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_action_check" CHECK ("occurrence_events"."action" IN ('take', 'skip', 'undo', 'correct', 'miss'));--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_from_state_check" CHECK ("occurrence_events"."from_state" IN ('pending', 'taken', 'skipped', 'missed'));--> statement-breakpoint
ALTER TABLE "occurrence_events" ADD CONSTRAINT "occurrence_events_to_state_check" CHECK ("occurrence_events"."to_state" IN ('pending', 'taken', 'skipped', 'missed'));
