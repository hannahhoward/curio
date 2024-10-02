-- Piece Park adjustments

ALTER TABLE parked_pieces ADD COLUMN long_term BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE parked_pieces DROP CONSTRAINT IF EXISTS parked_pieces_piece_cid_key;
ALTER TABLE parked_pieces ADD CONSTRAINT parked_pieces_piece_cid_cleanup_task_id_key UNIQUE (piece_cid, piece_padded_size, long_term, cleanup_task_id);

ALTER TABLE parked_piece_refs ADD COLUMN long_term BOOLEAN NOT NULL DEFAULT FALSE;

-- PDP tables

CREATE TABLE pdp_owner_addresses (
    owner_address TEXT NOT NULL PRIMARY KEY,
    private_key BYTEA NOT NULL
);

-- PDP services authenticate with ecdsa-sha256 keys; Allowed services here
CREATE TABLE pdp_services (
    id BIGSERIAL PRIMARY KEY,
    pubkey BYTEA NOT NULL,

    -- service_url TEXT NOT NULL,
    service_label TEXT NOT NULL,

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    UNIQUE(pubkey)
);

CREATE TABLE pdp_piece_uploads (
    id UUID PRIMARY KEY NOT NULL,
    service_id BIGINT NOT NULL, -- pdp_services.id

    piece_cid TEXT NOT NULL, -- piece cid v2
    notify_url TEXT NOT NULL, -- URL to notify when piece is ready

    piece_ref BIGINT, -- packed_piece_refs.ref_id

    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    FOREIGN KEY (service_id) REFERENCES pdp_services(id) ON DELETE CASCADE,
    FOREIGN KEY (piece_ref) REFERENCES parked_piece_refs(ref_id) ON DELETE SET NULL
);

-- PDP piece references, this table tells Curio which pieces in storage are managed by PDP
CREATE TABLE pdp_piecerefs (
    id BIGSERIAL PRIMARY KEY,
    service_id BIGINT NOT NULL, -- pdp_services.id
    piece_cid TEXT NOT NULL, -- piece cid v2
    piece_ref TEXT NOT NULL, -- parked_piece_refs.ref_id
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,

    proofset_refcount BIGINT NOT NULL DEFAULT 0, -- maintained by triggers

    UNIQUE(piece_ref),
    FOREIGN KEY (service_id) REFERENCES pdp_services(id) ON DELETE CASCADE,
    FOREIGN KEY (piece_ref) REFERENCES parked_piece_refs(ref_id) ON DELETE CASCADE
);

-- PDP proofsets we maintain
CREATE TABLE pdp_proof_sets (
    id BIGINT PRIMARY KEY, -- on-chain proofset id

    -- cached chain values
    next_challenge_epoch BIGINT -- next challenge epoch
);

-- proofset roots
CREATE TABLE pdp_proofset_roots (
    proofset BIGINT NOT NULL, -- pdp_proof_sets.id
    root_id BIGINT NOT NULL, -- on-chain index of the root in the rootCids sub-array
    root TEXT NOT NULL, -- root cid (piececid v2)

    -- aggregation roots (aggregated like pieces in filecoin sectors)
    subroot TEXT NOT NULL, -- subroot cid (piececid v2), with no aggregation this == root
    subroot_offset BIGINT NOT NULL, -- offset of the subroot in the root
    -- note: size contained in subroot piececid v2

    pdp_pieceref BIGINT NOT NULL, -- pdp_piecerefs.id

    CONSTRAINT pdp_proofset_roots_pk PRIMARY KEY (proofset, root_id, subroot_offset),

    FOREIGN KEY (proofset) REFERENCES pdp_proof_sets(id) ON DELETE CASCADE, -- cascade, if we drop a proofset, we no longer care about the roots
    FOREIGN KEY (pdp_pieceref) REFERENCES pdp_piecerefs(id) ON DELETE SET NULL -- sets null on delete so that it's easy to notice and clean up
);

CREATE TABLE pdp_prove_tasks (
    proofset BIGINT NOT NULL, -- pdp_proof_sets.id
    challenge_epoch BIGINT NOT NULL, -- challenge epoch

    task_id BIGINT NOT NULL, -- harmonytask task ID

    message_cid          text,
    message_eth_hash     text,

    FOREIGN KEY (proofset) REFERENCES pdp_proof_sets(id) ON DELETE CASCADE,
    CONSTRAINT pdp_prove_tasks_pk PRIMARY KEY (proofset, challenge_epoch)
);

-- proofset_refcount tracking
CREATE OR REPLACE FUNCTION increment_proofset_refcount()
    RETURNS TRIGGER AS $$
BEGIN
    UPDATE pdp_piecerefs
    SET proofset_refcount = proofset_refcount + 1
    WHERE id = NEW.pdp_pieceref;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pdp_proofset_root_insert
    AFTER INSERT ON pdp_proofset_roots
    FOR EACH ROW
    WHEN (NEW.pdp_pieceref IS NOT NULL)
EXECUTE FUNCTION increment_proofset_refcount();

CREATE OR REPLACE FUNCTION decrement_proofset_refcount()
    RETURNS TRIGGER AS $$
BEGIN
    UPDATE pdp_piecerefs
    SET proofset_refcount = proofset_refcount - 1
    WHERE id = OLD.pdp_pieceref;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pdp_proofset_root_delete
    AFTER DELETE ON pdp_proofset_roots
    FOR EACH ROW
    WHEN (OLD.pdp_pieceref IS NOT NULL)
EXECUTE FUNCTION decrement_proofset_refcount();

CREATE OR REPLACE FUNCTION adjust_proofset_refcount_on_update()
    RETURNS TRIGGER AS $$
BEGIN
    IF OLD.pdp_pieceref IS DISTINCT FROM NEW.pdp_pieceref THEN
        -- Decrement count for old reference if not null
        IF OLD.pdp_pieceref IS NOT NULL THEN
            UPDATE pdp_piecerefs
            SET proofset_refcount = proofset_refcount - 1
            WHERE id = OLD.pdp_pieceref;
        END IF;
        -- Increment count for new reference if not null
        IF NEW.pdp_pieceref IS NOT NULL THEN
            UPDATE pdp_piecerefs
            SET proofset_refcount = proofset_refcount + 1
            WHERE id = NEW.pdp_pieceref;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pdp_proofset_root_update
    AFTER UPDATE ON pdp_proofset_roots
    FOR EACH ROW
EXECUTE FUNCTION adjust_proofset_refcount_on_update();