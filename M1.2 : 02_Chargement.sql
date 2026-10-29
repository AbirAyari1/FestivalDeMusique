/* =====================================================================
   FESTIVAL DE MUSIQUE — 02 : chargement des CSV et traitement des défauts
   Oracle 12.2+ — à exécuter avec F5 après l'import des 4 CSV dans STG_*.
   Le script est ré-exécutable : il vide les tables chargées au début.

   Chaque défaut est tracé dans la table ANOMALIE avec son traitement :
     CORRIGEE  : la ligne est chargée après correction
     FUSIONNEE : doublon de personne, ses billets sont réaffectés
     REJETEE   : la ligne n'est pas chargée (opération non valide)

   Défauts présents dans les fichiers du groupe 04 et traitement retenu :
     spectateurs.csv
       - e-mail avec espaces ou majuscules ...................... CORRIGEE
       - même personne saisie deux fois (même e-mail normalisé,
         même nom, prénom, téléphone) ........................... FUSIONNEE
         -> on garde le plus petit identifiant ; les billets de
            l'autre identifiant lui sont rattachés
       - spectateurs sans e-mail : ce ne sont pas des défauts,
         chaque ligne reste une personne distincte
     billets.csv
       - ressource inexistante (id_concert absent de concerts) .. REJETEE
       - montant négatif ........................................ REJETEE
       - date de l'opération après le début du concert .......... REJETEE
       - même opération enregistrée deux fois (mêmes spectateur,
         concert, date, places, montant, statut, groupe ; seul
         l'id_billet change), surtout pendant le pic de mise en
         vente -> on garde le premier id_billet ............... REJETEE
     Signalés mais conservés (ce ne sont pas des erreurs de saisie) :
       - 16 concerts en sur-réservation de 1 à 3 places : on ne peut
         pas savoir quelle opération retirer ; mesuré par C7
       - concerts qui se chevauchent sur une même scène : listés en fin
         de script
     Contrôles faits mais sans défaut dans ces fichiers : identifiants non
     numériques, dates impossibles, montant différent de places x prix,
     nombre de places hors 1..10, statut inconnu, usager inexistant.

   Groupes d'achat : ton modèle relie les billets d'un même groupe par
   l'association réflexive BILLET.id_billet_groupe. Chaque billet d'un
   groupe y reçoit le plus petit id_billet valide du groupe (le billet
   « de tête » se référence lui-même).
   ===================================================================== */

SET DEFINE OFF;
SET SERVEROUTPUT ON;
ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD HH24:MI:SS';
ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS';

------------------------------------------------------------------------
-- 0. FONCTIONS DE CONVERSION : renvoient NULL au lieu de planter
------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION f_int (p_txt IN VARCHAR2) RETURN NUMBER IS
  PRAGMA UDF;
  v VARCHAR2(200) := TRIM(p_txt);
BEGIN
  IF v IS NULL OR NOT REGEXP_LIKE(v, '^[0-9]+$') THEN RETURN NULL; END IF;
  RETURN TO_NUMBER(v);
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
/

-- Décimal avec point ou virgule, indépendant du réglage de langue Oracle
CREATE OR REPLACE FUNCTION f_num (p_txt IN VARCHAR2) RETURN NUMBER IS
  PRAGMA UDF;
  v   VARCHAR2(200);
  sep VARCHAR2(1) := SUBSTR(TO_CHAR(0.5, 'FM0D0'), 2, 1);
BEGIN
  v := REPLACE(REGEXP_REPLACE(p_txt, '[[:space:]]', ''), ',', '.');
  IF v IS NULL OR NOT REGEXP_LIKE(v, '^-?[0-9]+(\.[0-9]+)?$') THEN RETURN NULL; END IF;
  RETURN TO_NUMBER(REPLACE(v, '.', sep));
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
/

-- Date AAAA-MM-JJ avec ou sans heure ; date impossible -> NULL
CREATE OR REPLACE FUNCTION f_date (p_txt IN VARCHAR2) RETURN DATE IS
  PRAGMA UDF;
  v VARCHAR2(200) := TRIM(p_txt);
BEGIN
  IF v IS NULL THEN RETURN NULL; END IF;
  IF    REGEXP_LIKE(v, '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$') THEN
    RETURN TO_DATE(v, 'FXYYYY-MM-DD HH24:MI:SS');
  ELSIF REGEXP_LIKE(v, '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') THEN
    RETURN TO_DATE(v, 'FXYYYY-MM-DD');
  END IF;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END;
/

------------------------------------------------------------------------
-- 1. REMISE À ZÉRO
------------------------------------------------------------------------

DELETE FROM BILLET;
DELETE FROM RATTACHER;
DELETE FROM SPECTATEUR;
DELETE FROM PERSONNE p
WHERE NOT EXISTS (SELECT 1 FROM ARTISTE a WHERE a.id_personne = p.id_personne);
DELETE FROM CONCERT;   -- si JOUER contient des lignes, vider JOUER d'abord
DELETE FROM SCENE;
COMMIT;

BEGIN
  FOR t IN (SELECT table_name FROM user_tables
            WHERE table_name IN ('ANOMALIE','W_SPECTATEURS','W_BILLETS')) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE "' || t.table_name || '" PURGE';
  END LOOP;
END;
/

CREATE TABLE ANOMALIE (
    id_anomalie   NUMBER GENERATED ALWAYS AS IDENTITY,
    table_source  VARCHAR2(30)  NOT NULL,
    id_source     VARCHAR2(100),
    motif         VARCHAR2(100) NOT NULL,
    traitement    VARCHAR2(20)  NOT NULL,
    detail        VARCHAR2(300),
    CONSTRAINT PK_ANOMALIE PRIMARY KEY (id_anomalie),
    CONSTRAINT CK_ANOMALIE_TRAITEMENT
        CHECK (traitement IN ('CORRIGEE', 'FUSIONNEE', 'REJETEE'))
);

------------------------------------------------------------------------
-- 2. SCÈNES
------------------------------------------------------------------------

INSERT INTO ANOMALIE (table_source, id_source, motif, traitement, detail)
SELECT 'SCENE', TRIM(id_scene), 'nom non conforme au modèle', 'CORRIGEE',
       TRIM(nom) || ' -> ' || REGEXP_REPLACE(TRIM(nom), '^site +', '', 1, 1, 'i')
FROM STG_SCENES
WHERE TRIM(nom) <> REGEXP_REPLACE(TRIM(nom), '^site +', '', 1, 1, 'i')
UNION ALL
SELECT 'SCENE', TRIM(id_scene), 'rôle mal saisi (casse)', 'CORRIGEE',
       TRIM(role) || ' -> ' || INITCAP(TRIM(role))
FROM STG_SCENES
WHERE TRIM(role) <> INITCAP(TRIM(role))
UNION ALL
SELECT 'SCENE', TRIM(id_scene), 'identifiant invalide', 'REJETEE', NULL
FROM STG_SCENES
WHERE f_int(id_scene) IS NULL;

INSERT INTO SCENE (id_scene, nom, ville, role)
SELECT f_int(id_scene),
       REGEXP_REPLACE(TRIM(nom), '^site +', '', 1, 1, 'i'),
       TRIM(ville),
       INITCAP(TRIM(role))
FROM STG_SCENES
WHERE f_int(id_scene) IS NOT NULL;

------------------------------------------------------------------------
-- 3. SPECTATEURS -> PERSONNE + SPECTATEUR + RATTACHER
--    Une personne = un e-mail normalisé (minuscules, sans espaces).
--    Sans e-mail, chaque ligne est une personne distincte.
------------------------------------------------------------------------

CREATE TABLE W_SPECTATEURS AS
SELECT x.*,
       MIN(x.id_spectateur) OVER (PARTITION BY x.cle_personne) AS id_retenu
FROM (
  SELECT TRIM(s.id_spectateur)   AS id_source,
         f_int(s.id_spectateur)  AS id_spectateur,
         TRIM(s.nom)             AS nom,
         TRIM(s.prenom)          AS prenom,
         TRIM(s.email)           AS email_brut,
         LOWER(REGEXP_REPLACE(s.email, '[[:space:]]', '')) AS email,
         TRIM(s.telephone)       AS telephone,
         TRIM(s.ville)           AS ville,
         f_int(s.id_scene)       AS id_scene,
         f_date(s.date_inscription) AS date_inscription,
         NVL(LOWER(REGEXP_REPLACE(s.email, '[[:space:]]', '')),
             'ID:' || TRIM(s.id_spectateur)) AS cle_personne
  FROM STG_SPECTATEURS s
) x;

INSERT INTO ANOMALIE (table_source, id_source, motif, traitement, detail)
SELECT 'SPECTATEUR', id_source, 'identifiant invalide', 'REJETEE', NULL
FROM W_SPECTATEURS WHERE id_spectateur IS NULL
UNION ALL
SELECT 'SPECTATEUR', id_source, 'nom ou prénom manquant', 'REJETEE', NULL
FROM W_SPECTATEURS
WHERE id_spectateur = id_retenu AND (nom IS NULL OR prenom IS NULL)
UNION ALL
SELECT 'SPECTATEUR', id_source, 'personne en double (même e-mail)', 'FUSIONNEE',
       'fusionnée avec le spectateur ' || id_retenu
FROM W_SPECTATEURS WHERE id_spectateur <> id_retenu
UNION ALL
SELECT 'SPECTATEUR', id_source, 'e-mail avec espaces ou majuscules', 'CORRIGEE',
       '"' || email_brut || '" -> ' || email
FROM W_SPECTATEURS
WHERE id_spectateur = id_retenu AND email_brut <> email
UNION ALL
SELECT 'SPECTATEUR', id_source, 'e-mail invalide', 'CORRIGEE', email || ' -> NULL'
FROM W_SPECTATEURS
WHERE id_spectateur = id_retenu
  AND NOT REGEXP_LIKE(email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
UNION ALL
SELECT 'SPECTATEUR', id_source, 'téléphone invalide', 'CORRIGEE', telephone || ' -> NULL'
FROM W_SPECTATEURS
WHERE id_spectateur = id_retenu
  AND NOT REGEXP_LIKE(telephone, '^(\+33[1-9]|0[1-9])[0-9]{8}$')
UNION ALL
SELECT 'SPECTATEUR', id_source, 'site de rattachement inconnu', 'CORRIGEE', 'id_scene -> NULL'
FROM W_SPECTATEURS w
WHERE w.id_spectateur = w.id_retenu
  AND NOT EXISTS (SELECT 1 FROM SCENE sc WHERE sc.id_scene = w.id_scene);

INSERT INTO PERSONNE (id_personne, nom, prenom)
SELECT id_spectateur, nom, prenom
FROM W_SPECTATEURS
WHERE id_spectateur = id_retenu
  AND nom IS NOT NULL AND prenom IS NOT NULL;

INSERT INTO SPECTATEUR (id_personne, ville, email, telephone, id_scene)
SELECT w.id_spectateur,
       w.ville,
       CASE WHEN REGEXP_LIKE(w.email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
            THEN w.email END,
       CASE WHEN REGEXP_LIKE(w.telephone, '^(\+33[1-9]|0[1-9])[0-9]{8}$')
            THEN w.telephone END,
       sc.id_scene
FROM W_SPECTATEURS w
JOIN PERSONNE p     ON p.id_personne = w.id_spectateur
LEFT JOIN SCENE sc  ON sc.id_scene   = w.id_scene
WHERE w.id_spectateur = w.id_retenu;

INSERT INTO RATTACHER (id_personne, id_scene, date_inscription)
SELECT w.id_spectateur, w.id_scene, w.date_inscription
FROM W_SPECTATEURS w
JOIN SPECTATEUR sp ON sp.id_personne = w.id_spectateur
JOIN SCENE sc      ON sc.id_scene    = w.id_scene
WHERE w.id_spectateur = w.id_retenu
  AND w.date_inscription IS NOT NULL;

------------------------------------------------------------------------
-- 4. CONCERTS (ressources)
------------------------------------------------------------------------

INSERT INTO ANOMALIE (table_source, id_source, motif, traitement, detail)
SELECT 'CONCERT', TRIM(c.id_concert),
       CASE
         WHEN f_int(c.id_concert) IS NULL                    THEN 'identifiant invalide'
         WHEN TRIM(c.libelle) IS NULL                        THEN 'libellé manquant'
         WHEN NOT EXISTS (SELECT 1 FROM SCENE sc
                          WHERE sc.id_scene = f_int(c.id_scene)) THEN 'scène inexistante'
         WHEN f_date(c.debut) IS NULL                        THEN 'début invalide'
         WHEN NVL(f_int(c.duree_minutes), 0) <= 0            THEN 'durée invalide'
         WHEN NVL(f_int(c.capacite), 0) <= 0                 THEN 'capacité invalide'
         WHEN f_num(c.prix_unitaire) IS NULL
           OR f_num(c.prix_unitaire) < 0                     THEN 'prix invalide'
         ELSE 'identifiant en double'
       END,
       'REJETEE', NULL
FROM STG_CONCERTS c
WHERE f_int(c.id_concert) IS NULL
   OR TRIM(c.libelle) IS NULL
   OR NOT EXISTS (SELECT 1 FROM SCENE sc WHERE sc.id_scene = f_int(c.id_scene))
   OR f_date(c.debut) IS NULL
   OR NVL(f_int(c.duree_minutes), 0) <= 0
   OR NVL(f_int(c.capacite), 0) <= 0
   OR f_num(c.prix_unitaire) IS NULL
   OR f_num(c.prix_unitaire) < 0
   OR (SELECT COUNT(*) FROM STG_CONCERTS c2
       WHERE TRIM(c2.id_concert) = TRIM(c.id_concert)) > 1;

INSERT INTO CONCERT (id_concert, libelle, categorie, debut, duree_minutes,
                     capacite, prix_unitaire, id_scene)
SELECT f_int(c.id_concert),
       TRIM(c.libelle),
       LOWER(TRIM(c.categorie)),
       CAST(f_date(c.debut) AS TIMESTAMP),
       f_int(c.duree_minutes),
       f_int(c.capacite),
       f_num(c.prix_unitaire),
       f_int(c.id_scene)
FROM STG_CONCERTS c
WHERE f_int(c.id_concert) IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ANOMALIE a
                  WHERE a.table_source = 'CONCERT'
                    AND a.id_source = TRIM(c.id_concert));

------------------------------------------------------------------------
-- 5. BILLETS (opérations)
--    Table de travail : une ligne par billet du CSV, un indicateur 0/1
--    par motif de rejet. Une opération peut cumuler plusieurs motifs.
------------------------------------------------------------------------

CREATE TABLE W_BILLETS AS
SELECT z.*,
       f_id + f_usager + f_ressource + f_date + f_date_apres + f_montant
     + f_negatif + f_incoherent + f_places + f_statut + f_doublon AS nb_motifs
FROM (
  SELECT y.*,
         CASE WHEN y.id_billet   IS NULL THEN 1 ELSE 0 END AS f_id,
         CASE WHEN y.id_personne IS NULL THEN 1 ELSE 0 END AS f_usager,
         CASE WHEN y.debut       IS NULL THEN 1 ELSE 0 END AS f_ressource,
         CASE WHEN y.date_billet IS NULL THEN 1 ELSE 0 END AS f_date,
         CASE WHEN y.date_billet > y.debut THEN 1 ELSE 0 END AS f_date_apres,
         CASE WHEN y.montant     IS NULL THEN 1 ELSE 0 END AS f_montant,
         CASE WHEN y.montant < 0 THEN 1 ELSE 0 END AS f_negatif,
         CASE WHEN y.montant >= 0 AND y.montant <> y.nb_places * y.prix_unitaire
              THEN 1 ELSE 0 END AS f_incoherent,
         CASE WHEN y.nb_places IS NULL OR y.nb_places NOT BETWEEN 1 AND 10
              THEN 1 ELSE 0 END AS f_places,
         CASE WHEN y.statut IS NULL THEN 1 ELSE 0 END AS f_statut,
         CASE WHEN y.id_billet > y.id_original THEN 1 ELSE 0 END AS f_doublon
  FROM (
    SELECT x.*,
           m.id_retenu     AS id_personne,
           c.debut         AS debut,
           c.prix_unitaire AS prix_unitaire,
           MIN(x.id_billet) OVER (PARTITION BY m.id_retenu, x.id_concert, x.date_billet,
                                               x.nb_places, x.montant, x.statut,
                                               x.id_groupe) AS id_original
    FROM (
      SELECT TRIM(b.id_billet)      AS id_source,
             f_int(b.id_billet)     AS id_billet,
             f_int(b.id_spectateur) AS id_spectateur_source,
             f_int(b.id_concert)    AS id_concert,
             f_date(b.date_billet)  AS date_billet,
             f_int(b.nb_places)     AS nb_places,
             f_num(b.montant)       AS montant,
             CASE UPPER(TRIM(b.statut))
               WHEN 'CONFIRMEE' THEN 'PAYE'    WHEN 'CONFIRMÉE' THEN 'PAYE'
               WHEN 'ANNULEE'   THEN 'ANNULE'  WHEN 'ANNULÉE'   THEN 'ANNULE'
               WHEN 'RESERVEE'  THEN 'RESERVE' WHEN 'RÉSERVÉE'  THEN 'RESERVE'
             END                    AS statut,
             TRIM(b.id_groupe)      AS id_groupe
      FROM STG_BILLETS b
    ) x
    LEFT JOIN (SELECT w.id_spectateur, w.id_retenu
               FROM W_SPECTATEURS w
               JOIN SPECTATEUR sp ON sp.id_personne = w.id_retenu) m
           ON m.id_spectateur = x.id_spectateur_source
    LEFT JOIN CONCERT c ON c.id_concert = x.id_concert
  ) y
) z;

-- Traçabilité : une ligne d'anomalie par motif
INSERT INTO ANOMALIE (table_source, id_source, motif, traitement, detail)
SELECT 'BILLET', id_source, 'identifiant invalide', 'REJETEE', NULL
FROM W_BILLETS WHERE f_id = 1
UNION ALL
SELECT 'BILLET', id_source, 'usager inexistant', 'REJETEE',
       'id_spectateur ' || id_spectateur_source
FROM W_BILLETS WHERE f_usager = 1
UNION ALL
SELECT 'BILLET', id_source, 'ressource inexistante', 'REJETEE',
       'id_concert ' || id_concert
FROM W_BILLETS WHERE f_ressource = 1
UNION ALL
SELECT 'BILLET', id_source, 'date invalide', 'REJETEE', NULL
FROM W_BILLETS WHERE f_date = 1
UNION ALL
SELECT 'BILLET', id_source, 'date après le début du concert', 'REJETEE',
       'opération ' || TO_CHAR(date_billet, 'YYYY-MM-DD HH24:MI') ||
       ', concert ' || TO_CHAR(debut, 'YYYY-MM-DD HH24:MI')
FROM W_BILLETS WHERE f_date_apres = 1
UNION ALL
SELECT 'BILLET', id_source, 'montant invalide', 'REJETEE', NULL
FROM W_BILLETS WHERE f_montant = 1
UNION ALL
SELECT 'BILLET', id_source, 'montant négatif', 'REJETEE', 'montant ' || montant
FROM W_BILLETS WHERE f_negatif = 1
UNION ALL
SELECT 'BILLET', id_source, 'montant différent de places x prix', 'REJETEE', NULL
FROM W_BILLETS WHERE f_incoherent = 1
UNION ALL
SELECT 'BILLET', id_source, 'nombre de places invalide', 'REJETEE', NULL
FROM W_BILLETS WHERE f_places = 1
UNION ALL
SELECT 'BILLET', id_source, 'statut inconnu', 'REJETEE', NULL
FROM W_BILLETS WHERE f_statut = 1
UNION ALL
SELECT 'BILLET', id_source, 'opération en double', 'REJETEE',
       'identique au billet ' || id_original
FROM W_BILLETS WHERE f_doublon = 1
UNION ALL
SELECT 'BILLET', id_source, 'usager fusionné', 'CORRIGEE',
       'spectateur ' || id_spectateur_source || ' -> ' || id_personne
FROM W_BILLETS WHERE nb_motifs = 0 AND id_spectateur_source <> id_personne;

INSERT INTO BILLET (id_billet, date_billet, nb_places, montant, statut,
                    id_spectateur, id_billet_groupe, id_concert)
SELECT id_billet, date_billet, nb_places, montant, statut,
       id_personne, NULL, id_concert
FROM W_BILLETS
WHERE nb_motifs = 0;

-- Groupes : chaque billet du groupe pointe vers le billet de tête
MERGE INTO BILLET b
USING (
  SELECT id_billet,
         MIN(id_billet) OVER (PARTITION BY id_groupe) AS id_tete
  FROM W_BILLETS
  WHERE nb_motifs = 0 AND id_groupe IS NOT NULL
) g
ON (b.id_billet = g.id_billet)
WHEN MATCHED THEN UPDATE SET b.id_billet_groupe = g.id_tete;

COMMIT;

-- Index sur les clés étrangères (Oracle ne les crée pas automatiquement) :
-- indispensables pour que les jointures et la division restent rapides.
BEGIN
  FOR i IN (SELECT index_name FROM user_indexes
            WHERE index_name IN ('IX_BILLET_SPECT','IX_BILLET_CONCERT',
                                 'IX_BILLET_GROUPE','IX_CONCERT_SCENE')) LOOP
    EXECUTE IMMEDIATE 'DROP INDEX ' || i.index_name;
  END LOOP;
END;
/
CREATE INDEX IX_BILLET_SPECT   ON BILLET (id_spectateur);
CREATE INDEX IX_BILLET_CONCERT ON BILLET (id_concert);
CREATE INDEX IX_BILLET_GROUPE  ON BILLET (id_billet_groupe);
CREATE INDEX IX_CONCERT_SCENE  ON CONCERT (id_scene);

------------------------------------------------------------------------
-- 6. BILAN
------------------------------------------------------------------------

SELECT 'SCENE' AS table_cible,
       (SELECT COUNT(*) FROM STG_SCENES) AS lignes_csv,
       (SELECT COUNT(*) FROM SCENE)      AS lignes_chargees
FROM dual
UNION ALL SELECT 'PERSONNE / SPECTATEUR', (SELECT COUNT(*) FROM STG_SPECTATEURS), (SELECT COUNT(*) FROM SPECTATEUR) FROM dual
UNION ALL SELECT 'RATTACHER', NULL, (SELECT COUNT(*) FROM RATTACHER) FROM dual
UNION ALL SELECT 'CONCERT', (SELECT COUNT(*) FROM STG_CONCERTS), (SELECT COUNT(*) FROM CONCERT) FROM dual
UNION ALL SELECT 'BILLET',  (SELECT COUNT(*) FROM STG_BILLETS),  (SELECT COUNT(*) FROM BILLET)  FROM dual;

SELECT table_source, motif, traitement, COUNT(*) AS nombre
FROM ANOMALIE
GROUP BY table_source, motif, traitement
ORDER BY table_source, nombre DESC;

-- Alerte sans traitement : concerts qui se chevauchent sur une même scène
SELECT c1.id_scene, c1.id_concert, c1.debut, c2.id_concert AS chevauche, c2.debut AS debut_2
FROM CONCERT c1
JOIN CONCERT c2
  ON  c2.id_scene   = c1.id_scene
  AND c2.id_concert <> c1.id_concert
  AND c2.debut >= c1.debut
  AND c2.debut <  c1.debut + NUMTODSINTERVAL(c1.duree_minutes, 'MINUTE')
  AND (c2.debut > c1.debut OR c2.id_concert > c1.id_concert)
ORDER BY c1.id_scene, c1.debut;
