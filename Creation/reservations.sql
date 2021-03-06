/* VUE CALENDRIER */
CREATE OR REPLACE VIEW calendrier AS
 SELECT
  numeropavillon,
  numerolocal,
  date,
  cip,
  nom AS description,
  MIN(numerobloc) AS blocDebut,
  MAX(numerobloc) AS blocFin
  FROM evenements
  JOIN reservations USING (evenementid)
  GROUP BY numeropavillon, numerolocal, date, cip, nom;

--------- SUPPRESSION ---------

/* SUPPRESSION RESERVATIONS */
CREATE OR REPLACE FUNCTION supprimer_reservations_local(local INTEGER, pavillon VARCHAR(16), debut INTEGER, fin INTEGER, date_res TIMESTAMP) RETURNS VOID AS $$
DECLARE
  evenement_id INTEGER;
BEGIN
  WHILE debut <= fin
  LOOP
    evenement_id := (SELECT evenementid FROM reservations WHERE (
           numerolocal=local
           AND numeropavillon=pavillon
           AND date=date_res
           AND numerobloc=debut
        ));

    IF evenement_id IS NOT NULL THEN
      DELETE FROM evenements WHERE evenementid=evenement_id;
    END IF;

    debut := debut + 1;
  END LOOP;

END;
$$ LANGUAGE plpgsql;

/* SUPPRESSION EVENEMENTs */
CREATE OR REPLACE FUNCTION supprimer_evenements(reservation calendrier, raise BOOLEAN DEFAULT TRUE) RETURNS VOID AS $$
DECLARE
  categorie INTEGER;
  sum_overwrite INTEGER;
  sous_local locaux%ROWTYPE;
BEGIN
  SELECT categorieid INTO categorie FROM locaux
    WHERE numerolocal=reservation.numerolocal AND numeropavillon=reservation.numeropavillon;

  SELECT SUM(override) INTO sum_overwrite FROM privilegesreservation
    WHERE categorieid=categorie AND statusid IN (SELECT statusid
                                                 FROM statusmembre
                                                 WHERE cip=reservation.cip);



  IF sum_overwrite = 0 OR sum_overwrite IS NULL THEN
    IF raise THEN
      RAISE EXCEPTION 'Vous ne pouvez pas supprimer les evenements pour ce local';
    ELSE
      RETURN;
    END IF;
  END IF;

  PERFORM supprimer_reservations_local(reservation.numerolocal, reservation.numeropavillon, reservation.blocDebut, reservation.blocFin, reservation.date);

  FOR sous_local IN SELECT * FROM locaux WHERE numerolocalparent=reservation.numerolocal and numeropavillonparent=reservation.numeropavillon LOOP
    PERFORM supprimer_reservations_local(sous_local.numerolocal, sous_local.numeropavillon, reservation.blocDebut, reservation.blocFin, reservation.date);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

/* TRIGGER SUPPRESSION */
CREATE OR REPLACE FUNCTION trigger_suppression_evenement() RETURNS TRIGGER AS $$
BEGIN
  -- Verification si est un sous-local avec parent reserve
  PERFORM verification_sous_local_reserve(OLD.numerolocal, OLD.numeropavillon, OLD.blocDebut, OLD.blocFin, OLD.date);

  PERFORM supprimer_evenements(OLD);

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

--------- AJOUT ---------

/* VERIFICATION SI PLAGE LIBRE */
CREATE OR REPLACE FUNCTION verification_disponibilite_plage(local INTEGER, pavillon VARCHAR(16), debut INTEGER, fin INTEGER, date_res TIMESTAMP) RETURNS VOID AS $$
DECLARE
  reservations_count INTEGER;
BEGIN
  WHILE debut <= fin
  LOOP
    reservations_count := (SELECT COUNT(*) FROM reservations WHERE (
           numerolocal=local AND numeropavillon=pavillon AND date=date_res AND numerobloc=debut
        ));
    IF (reservations_count != 0) THEN
      RAISE EXCEPTION 'Local est reserve pour cette periode';
    END IF;
    debut := debut + 1;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

/* VERIFICATION DE LA DISPONIBILITE DES SOUS-LOCAUX */
CREATE OR REPLACE FUNCTION verification_disponibilite_sous_locaux(local INTEGER, pavillon VARCHAR(16), debut INTEGER, fin INTEGER, date_res TIMESTAMP) RETURNS VOID AS $$
DECLARE
  sous_local locaux%ROWTYPE;
BEGIN
  FOR sous_local IN SELECT * FROM locaux WHERE numerolocalparent=local and numeropavillonparent=pavillon LOOP
    PERFORM verification_disponibilite_plage(sous_local.numerolocal, sous_local.numeropavillon, debut, fin, date_res);
  END LOOP;
END;
$$ LANGUAGE plpgsql;

/* VERIFICATION DE LA PLAGE HORAIRE DE LA CATEGORIE */
CREATE OR REPLACE FUNCTION verification_plage_categorie(local INTEGER, pavillon VARCHAR(16), debut INTEGER, fin INTEGER) RETURNS VOID AS $$
DECLARE
  categorie INTEGER;
  categorie_debut INTEGER;
  categorie_fin INTEGER;
BEGIN
  SELECT categorieid INTO categorie FROM locaux WHERE numerolocal=local AND numeropavillon=pavillon;
  SELECT blocdebut, blocfin INTO categorie_debut, categorie_fin FROM categories WHERE categorieid=categorie;

  IF debut < categorie_debut OR fin > categorie_fin THEN
    RAISE EXCEPTION 'Reservation en dehors de la plage de la categorie';
  END IF;
END;
$$ LANGUAGE plpgsql;

/* VERIFICATION DROIT RESERVATION */
CREATE OR REPLACE FUNCTION verification_droit_reservation(reservation calendrier) RETURNS VOID AS $$
DECLARE
  categorie INTEGER;
  faculte INTEGER;
  departement INTEGER;
  sum_plusde24h INTEGER;
  sum_ecriture INTEGER;
  max_temps INTERVAL;
  diff_temps INTERVAL;
BEGIN
  SELECT categorieid INTO categorie FROM locaux
    WHERE numerolocal=reservation.numerolocal AND numeropavillon=reservation.numeropavillon;
  SELECT faculteid, departementid INTO faculte, departement FROM membres
    WHERE cip=reservation.cip;

  -- Privileges
  SELECT SUM(ecriture), SUM(plusde24h) INTO sum_ecriture, sum_plusde24h FROM privilegesreservation
    WHERE categorieid=categorie AND statusid IN (SELECT statusid
                                                 FROM statusmembre
                                                 WHERE cip=reservation.cip);

  IF sum_ecriture = 0 OR sum_ecriture IS NULL THEN
    RAISE EXCEPTION 'Vous ne pouvez pas reserver ce local';
  END IF;

  -- Temps avant reservation
  SELECT MAX(numerobloc) * INTERVAL '15 minutes' INTO max_temps FROM tempsavantreservation
    WHERE categorieid=categorie AND departementid=departement AND faculteid=faculte AND statusid IN (SELECT statusid
                                                                                                     FROM statusmembre
                                                                                                     WHERE cip=reservation.cip);

  diff_temps := (reservation.date + reservation.blocDebut * INTERVAL '15 minutes') - now();

  IF (max_temps IS NULL OR diff_temps > max_temps) AND (sum_plusde24h = 0 OR sum_plusde24h IS NULL) THEN
    RAISE EXCEPTION 'Vous ne pouvez pas reserver autant davance: %s', diff_temps;
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION verification_date_heure(debut INTEGER, fin INTEGER, date DATE) RETURNS VOID AS $$
BEGIN
  IF fin < 0 OR fin > 95 THEN
    RAISE EXCEPTION 'Fin doit etre entre 0 et 95';
  END IF;

  IF debut < 0 OR debut > 95 THEN
    RAISE EXCEPTION 'Debut doit etre entre 0 et 95';
  END IF;

  IF fin < debut THEN
    RAISE EXCEPTION 'Fin doit etre apres debut';
  END IF;

  IF date < CURRENT_DATE THEN
    RAISE EXCEPTION 'Date ne peut etre dans le passe';
  END IF;
END;
$$ LANGUAGE plpgsql;

/* VERIFICATION SI SOUS-LOCAL ET PARENT RESERVE */
CREATE OR REPLACE FUNCTION verification_sous_local_reserve(local INTEGER, pavillon VARCHAR(16), debut INTEGER, fin INTEGER, date_res TIMESTAMP) RETURNS VOID AS $$
DECLARE
  local_parent INTEGER;
BEGIN
  SELECT numerolocalparent INTO local_parent FROM locaux WHERE numerolocal=local AND numeropavillon=pavillon;

  -- Si a un parent reserve -> throw
  if local_parent IS NOT NULL THEN
    PERFORM verification_disponibilite_plage(local_parent, pavillon, debut, fin, date_res);
  END IF;
END;
$$ LANGUAGE plpgsql;

/* TRIGGER AJOUT */
CREATE OR REPLACE FUNCTION trigger_ajout_reservation() RETURNS TRIGGER AS $$
DECLARE
  event_id INTEGER;
  sous_local INTEGER;
  sous_locaux INTEGER[];
BEGIN
  -- Verification de la validite de la date et heure
  PERFORM verification_date_heure(NEW.blocDebut, NEW.blocFin, NEW.date);

  -- Verification des permissions
  PERFORM verification_droit_reservation(NEW);

  -- Verification debut fin de la categorie
  PERFORM verification_plage_categorie(NEW.numerolocal, NEW.numeropavillon, NEW.blocDebut, NEW.blocFin);

  -- Verification si est un sous-local avec parent reserve
  PERFORM verification_sous_local_reserve(NEW.numerolocal, NEW.numeropavillon, NEW.blocDebut, NEW.blocFin, NEW.date);

  -- Essaye de supprimer evenements existants si a les droits override
  PERFORM supprimer_evenements(NEW, FALSE);

  -- Verification sous-locaux
  PERFORM verification_disponibilite_sous_locaux(NEW.numerolocal, NEW.numeropavillon, NEW.blocDebut, NEW.blocFin, NEW.date);

  -- Create new event
  SELECT MAX(evenementid) INTO event_id FROM evenements;
  IF event_id IS NULL THEN
    event_id := 0;
  ELSE
    event_id := event_id + 1;
  END IF;
  INSERT INTO evenements VALUES (event_id, NEW.description);

  -- Create reservations
  SELECT array_agg(numerolocal) INTO sous_locaux FROM locaux WHERE numerolocalparent=NEW.numerolocal and numeropavillonparent=NEW.numeropavillon;
  WHILE NEW.blocdebut <= NEW.blocfin
  LOOP
    INSERT INTO reservations VALUES (NEW.numeropavillon, NEW.numerolocal, NEW.date, NEW.blocDebut, event_id, NEW.cip);

    IF sous_locaux IS NOT NULL THEN
      FOREACH sous_local IN ARRAY sous_locaux LOOP
        INSERT INTO reservations VALUES (NEW.numeropavillon, sous_local, NEW.date, NEW.blocDebut, event_id, NEW.cip);
      END LOOP;
    END IF;
    NEW.blocdebut := NEW.blocdebut + 1;

  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

/* AJOUT DU TRIGGER SUR LA VUE */
DROP TRIGGER IF EXISTS ajout_evenement_trigger ON calendrier;
CREATE TRIGGER ajout_evenement_trigger
INSTEAD OF INSERT ON calendrier
    FOR EACH ROW EXECUTE PROCEDURE trigger_ajout_reservation();

DROP TRIGGER IF EXISTS suppression_evenement_trigger ON calendrier;
CREATE TRIGGER suppression_evenement_trigger
INSTEAD OF DELETE ON calendrier
    FOR EACH ROW EXECUTE PROCEDURE trigger_suppression_evenement();
