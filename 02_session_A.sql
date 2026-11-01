/* =====================================================================
   FESTIVAL DE MUSIQUE - L4 : anomalie de concurrence, SESSION A
   À exécuter APRÈS L4/01_fiabilite.sql.


   Scénario
     Le concert de test 900001 a 10 places. A et B achètent chacun un
     forfait de 6 places au même moment.
     Partie 1 : procédure SANS verrou -> les deux achats passent,
                12 places vendues pour 10 : sur-réservation.
     Partie 2 : procédure AVEC verrou (SELECT ... FOR UPDATE) -> B attend
                la fin de A, recompte, et son achat est refusé.
   ===================================================================== */

-- A0 · affichage DBMS_OUTPUT et données de test --------------------------
SET SERVEROUTPUT ON;

BEGIN
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
  COMMIT;
  DBMS_OUTPUT.PUT_LINE('A0 : données de test créées. Concert 900001 : '
                       || PKG_FORFAIT.places_restantes(900001) || ' places restantes.');
END;
/


/* =====================================================================
   PARTIE 1 · L'ANOMALIE (procédure sans verrou)
   ===================================================================== */

-- A1 · A achète 6 places, SANS valider 
DECLARE
  v_tete NUMBER;
BEGIN
  PKG_FORFAIT.acheter_forfait_sans_verrou(900001,
    T_FORFAIT(T_LIGNE_FORFAIT(900001, 6)), v_tete);
  DBMS_OUTPUT.PUT_LINE('A1 : achat de 6 places accepté, billet ' || v_tete
                       || ' (pas encore validé)');
END;
/
-- -> passer en session B : étape B1

-- A2 · A valide 
COMMIT;
-- -> passer en session B : étape B2

-- A3 · constat : places vendues et journal d'audit 
SELECT c.id_concert, c.capacite,
       SUM(b.nb_places)              AS places_payees,
       SUM(b.nb_places) - c.capacite AS depassement
FROM CONCERT c
JOIN BILLET b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
WHERE c.id_concert = 900001
GROUP BY c.id_concert, c.capacite;


SELECT id_audit, TO_CHAR(date_action, 'HH24:MI:SS') AS heure, id_session,
       action, id_billet, nb_places_apres
FROM AUDIT_BILLET
WHERE id_concert = 900001
ORDER BY id_audit;


-- A4 · remise à zéro avant la partie 2 
DELETE FROM BILLET WHERE id_concert IN (900001, 900002);
COMMIT;


/* =====================================================================
   PARTIE 2 · LA CORRECTION (procédure avec verrou)
   ===================================================================== */

-- A5 · A achète 6 places avec la procédure corrigée, SANS valider 
DECLARE
  v_tete NUMBER;
BEGIN
  PKG_FORFAIT.acheter_forfait(900001,
    T_FORFAIT(T_LIGNE_FORFAIT(900001, 6)), v_tete);
  DBMS_OUTPUT.PUT_LINE('A5 : achat de 6 places accepté, billet ' || v_tete
                       || ' (pas encore validé, ligne CONCERT 900001 verrouillée)');
END;
/
-- -> passer en session B : étape B3 (B reste bloquée)

-- A6 · pendant que B attend : 
SELECT sid, event, blocking_session,
       ROUND(wait_time_micro / 1000000, 1) AS secondes_attente
FROM v$session
WHERE username = 'FESTIVAL'
  AND blocking_session IS NOT NULL;

-- A7 · A valide : B est débloquée et reçoit le refus ----------------------
COMMIT;
-- -> passer en session B : lire le résultat de B3, puis étape B4

-- A8 · constat --------------------------------------------------------------
SELECT c.id_concert, c.capacite,
       SUM(b.nb_places) AS places_payees,
       PKG_FORFAIT.places_restantes(c.id_concert) AS places_restantes
FROM CONCERT c
JOIN BILLET b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
WHERE c.id_concert = 900001
GROUP BY c.id_concert, c.capacite;

-- A9 · nettoyage -----------------------------------------------------------
DELETE FROM BILLET     WHERE id_concert IN (900001, 900002)
                          OR id_spectateur IN (900001, 900002);
DELETE FROM CONCERT    WHERE id_concert IN (900001, 900002);
DELETE FROM SPECTATEUR WHERE id_personne IN (900001, 900002);
DELETE FROM PERSONNE   WHERE id_personne IN (900001, 900002);
COMMIT;
