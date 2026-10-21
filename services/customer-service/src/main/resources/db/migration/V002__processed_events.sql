-- V002__processed_events.sql  (customer-service)
--
-- Every event received from the eKYC is recorded here by its eventId.
-- If the same event arrives twice (retries over REST today, redeliveries on Kafka later),
-- the second copy is detected and ignored. Same table works for both transports.

CREATE TABLE public.processed_events (
    event_id      uuid PRIMARY KEY,                 -- eventId sent by the producer
    event_type    text NOT NULL,                    -- e.g. 'kyc.status_changed'
    subject_id    uuid,                             -- the customer the event is about
    occurred_at   timestamptz NOT NULL,             -- when it happened at the producer
    result        text NOT NULL DEFAULT 'applied'
                  CHECK (result IN ('applied', 'stale')),  -- stale = older than what we already have
    processed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX processed_events_subject_idx ON public.processed_events (subject_id, occurred_at);
