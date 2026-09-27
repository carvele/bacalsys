-- =============================================================================
-- workout_version_immutability
-- Roadmap v1.2 · Sprint 3 · Task 3.3 (Section 10, Rule C)
--
-- A version is built unsealed, then sealed exactly once (is_sealed false → true,
-- sealed_at stamped by the trigger, every identity/business field unchanged).
-- From then on INSERT / UPDATE / DELETE on the version and on every descendant
-- block, item and set hard-fails with SQLSTATE 22000. There is no session
-- variable or role bypass. The descendant triggers check BOTH the OLD and the
-- NEW ancestry, so a child can be neither moved out of nor into a sealed version.
--
-- Hardening vs the Section 10 listing (finding F-S3-01): every trigger function
-- here is SECURITY DEFINER with an empty search_path. The descendant checks read
-- public.workout_versions; as SECURITY INVOKER they would be subject to the
-- caller's RLS and see zero rows for any role that holds DML but is not
-- RLS-exempt, which would silently disable immutability. Behaviour is otherwise
-- identical to the specification.
-- =============================================================================

-- 1. Versions ---------------------------------------------------------------------
CREATE FUNCTION app_private.prevent_sealed_version_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.is_sealed = true THEN
      RAISE EXCEPTION 'Workout versions are immutable: sealed versions cannot be deleted.' USING ERRCODE = '22000';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    -- The one permitted UPDATE: unsealed → sealed, with identity and notes untouched.
    IF OLD.is_sealed = false AND NEW.is_sealed = true THEN
      IF NEW.id IS DISTINCT FROM OLD.id
         OR NEW.template_id IS DISTINCT FROM OLD.template_id
         OR NEW.version_number IS DISTINCT FROM OLD.version_number
         OR NEW.notes IS DISTINCT FROM OLD.notes
         OR NEW.created_by IS DISTINCT FROM OLD.created_by
         OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'Workout versions are immutable: version identity and notes cannot be modified during sealing.'
          USING ERRCODE = '22000';
      END IF;
      NEW.sealed_at := now();
      RETURN NEW;
    END IF;

    -- Everything else (editing an unsealed version, or touching a sealed one) is prohibited.
    RAISE EXCEPTION 'Workout versions are immutable: updates to version records are prohibited.'
      USING ERRCODE = '22000';
  END IF;

  RETURN NEW;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.prevent_sealed_version_mutation() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_seal_workout_versions
BEFORE UPDATE OR DELETE ON public.workout_versions
FOR EACH ROW EXECUTE FUNCTION app_private.prevent_sealed_version_mutation();

-- 2. Blocks -----------------------------------------------------------------------
CREATE FUNCTION app_private.check_version_unsealed_for_block()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_old_sealed boolean;
  v_new_sealed boolean;
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
    SELECT is_sealed INTO v_old_sealed FROM public.workout_versions WHERE id = OLD.workout_version_id;
    IF v_old_sealed = true THEN
      RAISE EXCEPTION 'Workout versions are immutable: cannot modify, delete, or re-parent blocks of a sealed version.'
        USING ERRCODE = '22000';
    END IF;
  END IF;

  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    SELECT is_sealed INTO v_new_sealed FROM public.workout_versions WHERE id = NEW.workout_version_id;
    IF v_new_sealed = true THEN
      RAISE EXCEPTION 'Workout versions are immutable: cannot attach blocks to an already sealed version.'
        USING ERRCODE = '22000';
    END IF;
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.check_version_unsealed_for_block() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_immutable_workout_blocks
BEFORE INSERT OR UPDATE OR DELETE ON public.workout_blocks
FOR EACH ROW EXECUTE FUNCTION app_private.check_version_unsealed_for_block();

-- 3. Items ------------------------------------------------------------------------
CREATE FUNCTION app_private.check_version_unsealed_for_item()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_old_sealed boolean;
  v_new_sealed boolean;
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
    SELECT v.is_sealed INTO v_old_sealed
    FROM public.workout_blocks b
    JOIN public.workout_versions v ON v.id = b.workout_version_id
    WHERE b.id = OLD.block_id;

    IF v_old_sealed = true THEN
      RAISE EXCEPTION 'Workout versions are immutable: cannot modify, delete, or re-parent items of a sealed version.'
        USING ERRCODE = '22000';
    END IF;
  END IF;

  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    SELECT v.is_sealed INTO v_new_sealed
    FROM public.workout_blocks b
    JOIN public.workout_versions v ON v.id = b.workout_version_id
    WHERE b.id = NEW.block_id;

    IF v_new_sealed = true THEN
      RAISE EXCEPTION 'Workout versions are immutable: cannot attach items to an already sealed version.'
        USING ERRCODE = '22000';
    END IF;
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.check_version_unsealed_for_item() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_immutable_workout_items
BEFORE INSERT OR UPDATE OR DELETE ON public.workout_items
FOR EACH ROW EXECUTE FUNCTION app_private.check_version_unsealed_for_item();

-- 4. Sets -------------------------------------------------------------------------
CREATE FUNCTION app_private.check_version_unsealed_for_set()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_old_sealed boolean;
  v_new_sealed boolean;
BEGIN
  IF TG_OP = 'DELETE' OR TG_OP = 'UPDATE' THEN
    SELECT v.is_sealed INTO v_old_sealed
    FROM public.workout_items i
    JOIN public.workout_blocks b ON b.id = i.block_id
    JOIN public.workout_versions v ON v.id = b.workout_version_id
    WHERE i.id = OLD.workout_item_id;

    IF v_old_sealed = true THEN
      RAISE EXCEPTION 'Workout versions are immutable: cannot modify, delete, or re-parent sets of a sealed version.'
        USING ERRCODE = '22000';
    END IF;
  END IF;

  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    SELECT v.is_sealed INTO v_new_sealed
    FROM public.workout_items i
    JOIN public.workout_blocks b ON b.id = i.block_id
    JOIN public.workout_versions v ON v.id = b.workout_version_id
    WHERE i.id = NEW.workout_item_id;

    IF v_new_sealed = true THEN
      RAISE EXCEPTION 'Workout versions are immutable: cannot attach sets to an already sealed version.'
        USING ERRCODE = '22000';
    END IF;
  END IF;

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
REVOKE EXECUTE ON FUNCTION app_private.check_version_unsealed_for_set() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_immutable_workout_item_sets
BEFORE INSERT OR UPDATE OR DELETE ON public.workout_item_sets
FOR EACH ROW EXECUTE FUNCTION app_private.check_version_unsealed_for_set();
