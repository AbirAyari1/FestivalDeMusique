/* =====================================================================
   FESTIVAL DE MUSIQUE - L4 Fiabilité : triggers, journal d'audit,
   package du forfait multi-scènes 
   

   Contenu
     1. Suppression des objets L4 et des données de test éventuelles
     2. Séquence SEQ_BILLET (identifiants des nouveaux billets)
     3. Types T_LIGNE_FORFAIT / T_FORFAIT (contenu d'un forfait)
     4. Table AUDIT_BILLET (journal d'audit)
     5. Trigger TRG_BILLET_AUDIT       : journal d'audit des billets
        Trigger TRG_BILLET_DATE        : date d'achat <= début du concert
        Trigger TRG_BILLET_TRANSITION  : pas de réactivation d'un billet
                                         annulé, pas d'ajout de places
                                         hors du package
     6. Package PKG_FORFAIT : achat d'un forfait multi-scènes, tout ou
        rien, qui refuse la sur-réservation
     7. Tests automatiques (données de test insérées puis annulées par
        ROLLBACK : aucune donnée n'est laissée dans la base)
     8. Vérification : objets valides

   La démonstration de l'anomalie de concurrence se fait ensuite avec
   02_session_A.sql et 03_session_B.sql, dans deux sessions.

   ===================================================================== */

SET DEFINE OFF;
SET SERVEROUTPUT ON;

------------------------------------------------------------------------
-- 1. SUPPRESSION DES OBJETS L4 ET DES DONNÉES DE TEST
------------------------------------------------------------------------
BEGIN
  FOR o IN (SELECT object_name, object_type
            FROM user_objects
            WHERE object_name IN ('TRG_BILLET_AUDIT', 'TRG_BILLET_DATE',
                                  'TRG_BILLET_TRANSITION', 'PKG_FORFAIT',
                                  'T_FORFAIT', 'T_LIGNE_FORFAIT',
                                  'AUDIT_BILLET', 'SEQ_BILLET')
              AND object_type IN ('TRIGGER', 'PACKAGE', 'TYPE', 'TABLE', 'SEQUENCE')
            ORDER BY CASE object_type WHEN 'TRIGGER' THEN 1 WHEN 'PACKAGE' THEN 2
                                      WHEN 'TYPE'    THEN 3 WHEN 'TABLE'   THEN 4
                                      ELSE 5 END,
                     CASE object_name WHEN 'T_FORFAIT' THEN 1 ELSE 2 END) LOOP
    EXECUTE IMMEDIATE 'DROP ' || o.object_type || ' "' || o.object_name || '"'
                      || CASE o.object_type WHEN 'TYPE'  THEN ' FORCE'
                                            WHEN 'TABLE' THEN ' PURGE' END;
  END LOOP;
END;
/

-- Données de test laissées par une démonstration interrompue
-- (concerts et spectateurs d'identifiant 900001 et 900002)
DELETE FROM BILLET     WHERE id_concert IN (900001, 900002)
                          OR id_spectateur IN (900001, 900002);
DELETE FROM JOUER      WHERE id_concert IN (900001, 900002);
DELETE FROM CONCERT    WHERE id_concert IN (900001, 900002);
DELETE FROM RATTACHER  WHERE id_personne IN (900001, 900002);
DELETE FROM SPECTATEUR WHERE id_personne IN (900001, 900002);
DELETE FROM PERSONNE   WHERE id_personne IN (900001, 900002);
COMMIT;

------------------------------------------------------------------------
-- 2. SÉQUENCE DES NOUVEAUX BILLETS
------------------------------------------------------------------------
CREATE SEQUENCE SEQ_BILLET START WITH 1000000 INCREMENT BY 1 NOCACHE;

------------------------------------------------------------------------
-- 3. TYPES : une ligne de forfait = un concert et un nombre de places
------------------------------------------------------------------------
CREATE TYPE T_LIGNE_FORFAIT AS OBJECT (
  id_concert NUMBER,
  nb_places  NUMBER
);
/

CREATE TYPE T_FORFAIT AS TABLE OF T_LIGNE_FORFAIT;
/

------------------------------------------------------------------------
-- 4. JOURNAL D'AUDIT
------------------------------------------------------------------------
CREATE TABLE AUDIT_BILLET (
  id_audit         NUMBER GENERATED ALWAYS AS IDENTITY,
  date_action      TIMESTAMP     NOT NULL,
  utilisateur      VARCHAR2(128) NOT NULL,
  id_session       NUMBER,
  action           VARCHAR2(6)   NOT NULL,
  id_billet        NUMBER        NOT NULL,
  id_concert       NUMBER,
  statut_avant     VARCHAR2(30),
  statut_apres     VARCHAR2(30),
  nb_places_avant  NUMBER,
  nb_places_apres  NUMBER,
  montant_avant    NUMBER(10, 2),
  montant_apres    NUMBER(10, 2),
  CONSTRAINT PK_AUDIT_BILLET PRIMARY KEY (id_audit),
  CONSTRAINT CK_AUDIT_ACTION CHECK (action IN ('INSERT', 'UPDATE', 'DELETE'))
);

------------------------------------------------------------------------
-- 5. TRIGGERS
------------------------------------------------------------------------

-- 5.1 Journal d'audit : toute création, suppression ou modification
--     d'un billet (statut, places, montant, concert) est tracée avec
--     l'utilisateur, la session et les valeurs avant / après.
CREATE OR REPLACE TRIGGER TRG_BILLET_AUDIT
AFTER INSERT OR DELETE OR UPDATE OF statut, nb_places, montant, id_concert ON BILLET
FOR EACH ROW
DECLARE
  v_action AUDIT_BILLET.action%TYPE;
BEGIN
  v_action := CASE WHEN INSERTING THEN 'INSERT'
                   WHEN UPDATING  THEN 'UPDATE'
                   ELSE 'DELETE' END;
  INSERT INTO AUDIT_BILLET (date_action, utilisateur, id_session, action,
                            id_billet, id_concert,
                            statut_avant, statut_apres,
                            nb_places_avant, nb_places_apres,
                            montant_avant, montant_apres)
  VALUES (SYSTIMESTAMP,
          SYS_CONTEXT('USERENV', 'SESSION_USER'),
          TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')),
          v_action,
          NVL(:NEW.id_billet, :OLD.id_billet),
          NVL(:NEW.id_concert, :OLD.id_concert),
          :OLD.statut, :NEW.statut,
          :OLD.nb_places, :NEW.nb_places,
          :OLD.montant, :NEW.montant);
END;
/

-- 5.2 Règle de validité du sujet : la date de l'opération doit être
--     antérieure ou égale au début du concert (96 billets du CSV la
--     violaient). Si le concert n'existe pas, la clé étrangère
--     FK_BILLET_CONCERT refuse la ligne.
CREATE OR REPLACE TRIGGER TRG_BILLET_DATE
BEFORE INSERT OR UPDATE OF date_billet, id_concert ON BILLET
FOR EACH ROW
DECLARE
  v_debut CONCERT.debut%TYPE;
BEGIN
  SELECT debut INTO v_debut
  FROM CONCERT
  WHERE id_concert = :NEW.id_concert;

  IF :NEW.date_billet > v_debut THEN
    RAISE_APPLICATION_ERROR(-20011,
      'Billet ' || :NEW.id_billet || ' refusé : date '
      || TO_CHAR(:NEW.date_billet, 'DD/MM/YYYY HH24:MI')
      || ' postérieure au début du concert ' || :NEW.id_concert
      || ' (' || TO_CHAR(v_debut, 'DD/MM/YYYY HH24:MI') || ')');
  END IF;
EXCEPTION
  WHEN NO_DATA_FOUND THEN NULL;
END;
/

-- 5.3 Transitions de statut : un billet annulé ne redevient pas payé,
--     et un billet payé ne gagne pas de places ni ne change de concert
--     par un simple UPDATE. Ces deux modifications contourneraient le
--     contrôle de capacité du package.
CREATE OR REPLACE TRIGGER TRG_BILLET_TRANSITION
BEFORE UPDATE OF statut, nb_places, id_concert ON BILLET
FOR EACH ROW
BEGIN
  IF :OLD.statut = 'ANNULE' AND :NEW.statut <> 'ANNULE' THEN
    RAISE_APPLICATION_ERROR(-20010,
      'Billet ' || :OLD.id_billet || ' annulé : il ne peut pas être réactivé.'
      || ' Un nouvel achat doit passer par PKG_FORFAIT.');
  END IF;

  IF :OLD.statut = 'PAYE'
     AND (:NEW.nb_places > :OLD.nb_places OR :NEW.id_concert <> :OLD.id_concert) THEN
    RAISE_APPLICATION_ERROR(-20012,
      'Billet ' || :OLD.id_billet || ' payé : ajout de places ou changement de'
      || ' concert interdits hors de PKG_FORFAIT (contrôle de capacité).');
  END IF;
END;
/

------------------------------------------------------------------------
-- 6. PACKAGE DU FORFAIT MULTI-SCÈNES
--
--    acheter_forfait : version sûre.
--      - une seule transaction ; SAVEPOINT au début, ROLLBACK TO
--        SAVEPOINT à la moindre erreur : tout ou rien ;
--      - les concerts sont traités dans l'ordre croissant de leur
--        identifiant : deux forfaits concurrents verrouillent leurs
--        concerts dans le même ordre, ce qui évite l'interblocage ;
--      - pour chaque concert : SELECT ... FOR UPDATE sur sa ligne
--        CONCERT, puis calcul des places payées, puis insertion. Une
--        seconde session qui achète le même concert attend que la
--        première ait validé ou annulé, puis recompte ;
--      - la validation (COMMIT) est laissée à l'appelant.
--
--    acheter_forfait_sans_verrou : même traitement SANS le FOR UPDATE.
--      Sert uniquement à reproduire l'anomalie de concurrence (L4).
--
--    Codes d'erreur
--      -20001 forfait vide            -20004 concert déjà commencé
--      -20002 sur-réservation         -20005 ligne invalide
--      -20003 concert inexistant      -20006 spectateur inexistant
------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE PKG_FORFAIT AS

  -- Places encore disponibles : capacité - places des billets payés
  FUNCTION places_restantes (p_id_concert IN NUMBER) RETURN NUMBER;

  -- Achat d'un forfait, version sûre (verrouillage des concerts)
  PROCEDURE acheter_forfait (p_id_spectateur IN  NUMBER,
                             p_lignes        IN  T_FORFAIT,
                             p_id_tete       OUT NUMBER);

  -- DÉMONSTRATION L4 UNIQUEMENT : même achat sans verrou
  PROCEDURE acheter_forfait_sans_verrou (p_id_spectateur IN  NUMBER,
                                         p_lignes        IN  T_FORFAIT,
                                         p_id_tete       OUT NUMBER);
END PKG_FORFAIT;
/

CREATE OR REPLACE PACKAGE BODY PKG_FORFAIT AS

  FUNCTION places_restantes (p_id_concert IN NUMBER) RETURN NUMBER IS
    v_capacite CONCERT.capacite%TYPE;
    v_vendues  NUMBER;
  BEGIN
    SELECT capacite INTO v_capacite FROM CONCERT WHERE id_concert = p_id_concert;
    SELECT NVL(SUM(nb_places), 0) INTO v_vendues
    FROM BILLET
    WHERE id_concert = p_id_concert AND statut = 'PAYE';
    RETURN v_capacite - v_vendues;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
  END places_restantes;


  PROCEDURE acheter (p_id_spectateur IN  NUMBER,
                     p_lignes        IN  T_FORFAIT,
                     p_verrou        IN  BOOLEAN,
                     p_id_tete       OUT NUMBER) IS
    v_capacite CONCERT.capacite%TYPE;
    v_prix     CONCERT.prix_unitaire%TYPE;
    v_debut    CONCERT.debut%TYPE;
    v_vendues  NUMBER;
    v_id       BILLET.id_billet%TYPE;
    v_nb       PLS_INTEGER;
  BEGIN
    SAVEPOINT sp_forfait;
    p_id_tete := NULL;

    -- Contrôles de forme
    IF p_lignes IS NULL OR p_lignes.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20001, 'Forfait vide : au moins un concert est attendu.');
    END IF;

    FOR i IN 1 .. p_lignes.COUNT LOOP
      IF p_lignes(i).id_concert IS NULL
         OR p_lignes(i).nb_places IS NULL
         OR p_lignes(i).nb_places NOT BETWEEN 1 AND 10 THEN
        RAISE_APPLICATION_ERROR(-20005,
          'Ligne ' || i || ' du forfait invalide : concert obligatoire, 1 à 10 places.');
      END IF;
    END LOOP;

    SELECT COUNT(*) INTO v_nb FROM SPECTATEUR WHERE id_personne = p_id_spectateur;
    IF v_nb = 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Spectateur inexistant : ' || p_id_spectateur || '.');
    END IF;

    -- Concert par concert, dans l'ordre croissant des identifiants
    FOR c IN (SELECT id_concert, SUM(nb_places) AS demande
              FROM TABLE(p_lignes)
              GROUP BY id_concert
              ORDER BY id_concert) LOOP

      -- Lecture du concert, avec ou sans verrou de sa ligne
      BEGIN
        IF p_verrou THEN
          SELECT capacite, prix_unitaire, debut
          INTO v_capacite, v_prix, v_debut
          FROM CONCERT
          WHERE id_concert = c.id_concert
          FOR UPDATE;
        ELSE
          SELECT capacite, prix_unitaire, debut
          INTO v_capacite, v_prix, v_debut
          FROM CONCERT
          WHERE id_concert = c.id_concert;
        END IF;
      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          RAISE_APPLICATION_ERROR(-20003, 'Concert inexistant : ' || c.id_concert || '.');
      END;

      IF v_debut <= SYSTIMESTAMP THEN
        RAISE_APPLICATION_ERROR(-20004,
          'Concert ' || c.id_concert || ' déjà commencé le '
          || TO_CHAR(v_debut, 'DD/MM/YYYY HH24:MI') || ' : vente fermée.');
      END IF;

      -- Places déjà payées (lues après l'obtention du verrou)
      SELECT NVL(SUM(nb_places), 0) INTO v_vendues
      FROM BILLET
      WHERE id_concert = c.id_concert AND statut = 'PAYE';

      IF v_vendues + c.demande > v_capacite THEN
        RAISE_APPLICATION_ERROR(-20002,
          'Sur-réservation refusée : concert ' || c.id_concert
          || ', ' || c.demande || ' place(s) demandée(s), '
          || GREATEST(v_capacite - v_vendues, 0) || ' restante(s) sur '
          || v_capacite || '.');
      END IF;

      -- Un billet par ligne du forfait pour ce concert ; tous les
      -- billets pointent vers le premier (association réflexive)
      FOR l IN (SELECT nb_places FROM TABLE(p_lignes) WHERE id_concert = c.id_concert) LOOP
        v_id := SEQ_BILLET.NEXTVAL;
        IF p_id_tete IS NULL THEN
          p_id_tete := v_id;
        END IF;
        INSERT INTO BILLET (id_billet, date_billet, nb_places, montant, statut,
                            id_spectateur, id_billet_groupe, id_concert)
        VALUES (v_id, SYSDATE, l.nb_places, l.nb_places * v_prix, 'PAYE',
                p_id_spectateur, p_id_tete, c.id_concert);
      END LOOP;
    END LOOP;

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK TO SAVEPOINT sp_forfait;   -- tout ou rien
      p_id_tete := NULL;
      RAISE;
  END acheter;


  PROCEDURE acheter_forfait (p_id_spectateur IN  NUMBER,
                             p_lignes        IN  T_FORFAIT,
                             p_id_tete       OUT NUMBER) IS
  BEGIN
    acheter(p_id_spectateur, p_lignes, TRUE, p_id_tete);
  END acheter_forfait;


  PROCEDURE acheter_forfait_sans_verrou (p_id_spectateur IN  NUMBER,
                                         p_lignes        IN  T_FORFAIT,
                                         p_id_tete       OUT NUMBER) IS
  BEGIN
    acheter(p_id_spectateur, p_lignes, FALSE, p_id_tete);
  END acheter_forfait_sans_verrou;

END PKG_FORFAIT;
/

------------------------------------------------------------------------
-- 7. TESTS AUTOMATIQUES
--    Tout est fait dans une seule transaction annulée à la fin :
--    données de test, billets et lignes d'audit disparaissent.
--    Chaque test affiche OK ou ECHEC dans la Sortie de script.
--
--    Données de test
--      spectateurs 900001 (Test Session A) et 900002 (Test Session B)
--      concert 900001 : Scène Nord (id_scene 2), capacité 10, 50 €
--      concert 900002 : Scène Sud  (id_scene 3), capacité 5,  40 €
------------------------------------------------------------------------
DECLARE
  v_tete      NUMBER;
  v_tete_t1   NUMBER;
  v_n         NUMBER;
  v_billet_2  NUMBER;

  PROCEDURE ok (p_texte IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('OK      ' || p_texte);
  END;

  PROCEDURE echec (p_texte IN VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('ECHEC   ' || p_texte);
  END;

  PROCEDURE attendu (p_test IN VARCHAR2, p_code IN NUMBER) IS
  BEGIN
    IF SQLCODE = p_code THEN
      ok(p_test || ' -> refus attendu : ' || SQLERRM);
    ELSE
      echec(p_test || ' -> erreur inattendue : ' || SQLERRM);
    END IF;
  END;
BEGIN
  -- Données de test
  INSERT INTO PERSONNE (id_personne, nom, prenom) VALUES (900001, 'Test', 'Session A');
  INSERT INTO PERSONNE (id_personne, nom, prenom) VALUES (900002, 'Test', 'Session B');
  INSERT INTO SPECTATEUR (id_personne, ville, email, telephone, id_scene)
  VALUES (900001, 'Lyon', 'session.a@test.fr', NULL, 2);
  INSERT INTO SPECTATEUR (id_personne, ville, email, telephone, id_scene)
  VALUES (900002, 'Lyon', 'session.b@test.fr', NULL, 3);
  INSERT INTO CONCERT (id_concert, libelle, categorie, debut, duree_minutes,
                       capacite, prix_unitaire, id_scene)
  VALUES (900001, 'Concert test L4 Nord', 'rock',
          TIMESTAMP '2027-06-20 20:00:00', 120, 10, 50, 2);
  INSERT INTO CONCERT (id_concert, libelle, categorie, debut, duree_minutes,
                       capacite, prix_unitaire, id_scene)
  VALUES (900002, 'Concert test L4 Sud', 'jazz',
          TIMESTAMP '2027-06-21 20:00:00', 90, 5, 40, 3);

  DBMS_OUTPUT.PUT_LINE('--- Tests L4 ---');

  -- T1 : forfait valide sur deux sites
  PKG_FORFAIT.acheter_forfait(900001,
    T_FORFAIT(T_LIGNE_FORFAIT(900001, 2), T_LIGNE_FORFAIT(900002, 1)), v_tete);
  v_tete_t1 := v_tete;
  SELECT COUNT(*) INTO v_n FROM BILLET WHERE id_billet_groupe = v_tete_t1;
  IF v_n = 2 THEN
    ok('T1 forfait Nord + Sud accepté : 2 billets, billet de tête ' || v_tete_t1);
  ELSE
    echec('T1 forfait Nord + Sud : ' || v_n || ' billet(s) au lieu de 2');
  END IF;

  -- T2 : le journal d'audit a tracé les deux insertions
  SELECT COUNT(*) INTO v_n
  FROM AUDIT_BILLET
  WHERE action = 'INSERT'
    AND id_billet IN (SELECT id_billet FROM BILLET WHERE id_billet_groupe = v_tete_t1);
  IF v_n = 2 THEN
    ok('T2 journal d''audit : les 2 insertions sont tracées');
  ELSE
    echec('T2 journal d''audit : ' || v_n || ' ligne(s) au lieu de 2');
  END IF;

  -- T3 : sur-réservation refusée. Concert 900002 : 5 places, 1 vendue,
  --      le forfait en demande 5. Le concert 900001 (traité en premier)
  --      reçoit d'abord un billet, qui doit être annulé : tout ou rien.
  BEGIN
    PKG_FORFAIT.acheter_forfait(900002,
      T_FORFAIT(T_LIGNE_FORFAIT(900001, 3), T_LIGNE_FORFAIT(900002, 5)), v_tete);
    echec('T3 sur-réservation acceptée à tort');
  EXCEPTION
    WHEN OTHERS THEN attendu('T3 sur-réservation', -20002);
  END;

  -- T4 : tout ou rien, le billet du concert 900001 n'a pas été conservé
  SELECT NVL(SUM(nb_places), 0) INTO v_n
  FROM BILLET WHERE id_concert = 900001 AND statut = 'PAYE';
  IF v_n = 2 THEN
    ok('T4 tout ou rien : concert 900001 toujours à 2 places (le billet du forfait refusé a été annulé)');
  ELSE
    echec('T4 tout ou rien : concert 900001 à ' || v_n || ' places au lieu de 2');
  END IF;

  -- T5 : trigger de transition, un billet annulé ne redevient pas payé
  UPDATE BILLET SET statut = 'ANNULE' WHERE id_billet = v_tete_t1;
  BEGIN
    UPDATE BILLET SET statut = 'PAYE' WHERE id_billet = v_tete_t1;
    echec('T5 réactivation d''un billet annulé acceptée à tort');
  EXCEPTION
    WHEN OTHERS THEN attendu('T5 réactivation d''un billet annulé', -20010);
  END;

  -- T6 : trigger de transition, pas d'ajout de places sur un billet payé
  SELECT MAX(id_billet) INTO v_billet_2 FROM BILLET WHERE id_billet_groupe = v_tete_t1;
  BEGIN
    UPDATE BILLET SET nb_places = nb_places + 1 WHERE id_billet = v_billet_2;
    echec('T6 ajout de places sur un billet payé accepté à tort');
  EXCEPTION
    WHEN OTHERS THEN attendu('T6 ajout de places hors du package', -20012);
  END;

  -- T7 : trigger de date, achat postérieur au début du concert
  BEGIN
    INSERT INTO BILLET (id_billet, date_billet, nb_places, montant, statut,
                        id_spectateur, id_billet_groupe, id_concert)
    VALUES (SEQ_BILLET.NEXTVAL, DATE '2028-01-01', 1, 50, 'PAYE', 900001, NULL, 900001);
    echec('T7 billet daté après le début du concert accepté à tort');
  EXCEPTION
    WHEN OTHERS THEN attendu('T7 date après le début du concert', -20011);
  END;

  -- T8 : concert inexistant
  BEGIN
    PKG_FORFAIT.acheter_forfait(900001, T_FORFAIT(T_LIGNE_FORFAIT(999999, 1)), v_tete);
    echec('T8 concert inexistant accepté à tort');
  EXCEPTION
    WHEN OTHERS THEN attendu('T8 concert inexistant', -20003);
  END;

  -- T9 : concert déjà commencé (concert 1 du CSV, le 02/05/2026)
  BEGIN
    PKG_FORFAIT.acheter_forfait(900001, T_FORFAIT(T_LIGNE_FORFAIT(1, 1)), v_tete);
    echec('T9 vente sur un concert passé acceptée à tort');
  EXCEPTION
    WHEN OTHERS THEN attendu('T9 concert déjà commencé', -20004);
  END;

  -- T10 : spectateur inexistant
  BEGIN
    PKG_FORFAIT.acheter_forfait(999999, T_FORFAIT(T_LIGNE_FORFAIT(900001, 1)), v_tete);
    echec('T10 spectateur inexistant accepté à tort');
  EXCEPTION
    WHEN OTHERS THEN attendu('T10 spectateur inexistant', -20006);
  END;

  -- T11 : contenu du journal d'audit pour les concerts de test.
  --       Attendu : 2 INSERT (T1) + 1 UPDATE (T5). L'insertion du
  --       forfait refusé (T3) a été annulée avec lui : elle n'y est pas.
  SELECT COUNT(*) INTO v_n FROM AUDIT_BILLET WHERE id_concert IN (900001, 900002);
  IF v_n = 3 THEN
    ok('T11 journal d''audit : 3 lignes (2 INSERT, 1 UPDATE), rien pour le forfait refusé');
  ELSE
    echec('T11 journal d''audit : ' || v_n || ' ligne(s) au lieu de 3');
  END IF;

  ROLLBACK;
  DBMS_OUTPUT.PUT_LINE('--- Fin des tests : ROLLBACK, aucune donnée de test conservée ---');

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    DBMS_OUTPUT.PUT_LINE('ECHEC   erreur non prévue, tests interrompus : ' || SQLERRM);
    RAISE;
END;
/

------------------------------------------------------------------------
-- 8. VÉRIFICATION : tous les objets L4 doivent être VALID
------------------------------------------------------------------------
SELECT object_type, object_name, status
FROM user_objects
WHERE object_name IN ('TRG_BILLET_AUDIT', 'TRG_BILLET_DATE', 'TRG_BILLET_TRANSITION',
                      'PKG_FORFAIT', 'T_FORFAIT', 'T_LIGNE_FORFAIT',
                      'AUDIT_BILLET', 'SEQ_BILLET')
ORDER BY object_type, object_name;
