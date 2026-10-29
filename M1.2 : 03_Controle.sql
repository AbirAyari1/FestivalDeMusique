/* =====================================================================
   FESTIVAL DE MUSIQUE — 03 : valeurs de contrôle C1 à C9 et 10 requêtes
   Oracle — à exécuter après 02_chargement.sql (F5).
   Les résultats obtenus sur les données du groupe 04 sont indiqués en
   commentaire sous chaque requête.

   Correspondance sujet -> modèle :
     personne / usager     = SPECTATEUR (sous-type de PERSONNE)
     opération             = BILLET
     ressource             = CONCERT
     site                  = SCENE dont le rôle est 'Site' (le siège n'en est pas un)
     site d'une opération  = scène de son concert
     opération valide      = billet chargé dans BILLET (payé ou annulé)
     opération confirmée   = BILLET.statut = 'PAYE' (CONFIRMEE dans le CSV)
     opération groupée     = billets ayant le même id_billet_groupe
   ===================================================================== */

ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';

------------------------------------------------------------------------
-- C1 : nombre de personnes distinctes
------------------------------------------------------------------------
SELECT COUNT(*) AS c1_personnes_distinctes
FROM SPECTATEUR;
-- Résultat : 21 872
-- (21 962 lignes dans le CSV, dont 90 personnes saisies deux fois)

------------------------------------------------------------------------
-- C2 : nombre d'opérations non valides, et répartition par motif
------------------------------------------------------------------------
SELECT COUNT(DISTINCT id_source) AS c2_operations_non_valides
FROM ANOMALIE
WHERE table_source = 'BILLET' AND traitement = 'REJETEE';
-- Résultat : 607

SELECT motif, COUNT(*) AS nombre
FROM ANOMALIE
WHERE table_source = 'BILLET' AND traitement = 'REJETEE'
GROUP BY motif
ORDER BY nombre DESC;
-- Résultat :
--   ressource inexistante            400
--   date après le début du concert    96
--   montant négatif                   64
--   opération en double               47
-- (aucune opération ne cumule deux motifs : 400 + 96 + 64 + 47 = 607)

------------------------------------------------------------------------
-- C3 : nombre d'opérations valides confirmées
------------------------------------------------------------------------
SELECT COUNT(*) AS c3_operations_confirmees
FROM BILLET
WHERE statut = 'PAYE';
-- Résultat : 354 923   (+ 29 619 annulées = 384 542 opérations valides)

------------------------------------------------------------------------
-- C4 : jour où le plus d'opérations valides ont été passées, et leur nombre
------------------------------------------------------------------------
SELECT jour, nb_operations
FROM (
  SELECT TRUNC(date_billet) AS jour,
         COUNT(*)           AS nb_operations,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rang
  FROM BILLET
  GROUP BY TRUNC(date_billet)
)
WHERE rang = 1;
-- Résultat : 2026-03-18 avec 15 659 opérations
-- (c'est le pic de mise en vente : le jour suivant en a 784)

------------------------------------------------------------------------
-- C5 : chiffre d'affaires de chaque site
------------------------------------------------------------------------
SELECT s.id_scene, s.nom AS site,
       NVL(SUM(b.montant), 0) AS c5_chiffre_affaires
FROM SCENE s
LEFT JOIN CONCERT c ON c.id_scene   = s.id_scene
LEFT JOIN BILLET  b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
WHERE s.role = 'Site'
GROUP BY s.id_scene, s.nom
ORDER BY s.id_scene;
-- Résultat :
--   2  Scène Nord   23 131 964,00
--   3  Scène Sud    15 764 414,00
--   4  Scène Est    12 372 109,00
--   (total 51 268 487,00)

------------------------------------------------------------------------
-- C6 : nombre de personnes ayant des opérations valides sur au moins deux sites
------------------------------------------------------------------------
SELECT COUNT(*) AS c6_personnes_multi_sites
FROM (
  SELECT b.id_spectateur
  FROM BILLET b
  JOIN CONCERT c ON c.id_concert = b.id_concert
  JOIN SCENE   s ON s.id_scene   = c.id_scene AND s.role = 'Site'
  GROUP BY b.id_spectateur
  HAVING COUNT(DISTINCT c.id_scene) >= 2
);
-- Résultat : 13 016
-- (12 477 si on ne comptait que les opérations confirmées)

------------------------------------------------------------------------
-- C7 : nombre de ressources en sur-réservation
------------------------------------------------------------------------
SELECT COUNT(*) AS c7_ressources_sur_reservees
FROM (
  SELECT c.id_concert
  FROM CONCERT c
  JOIN BILLET b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
  GROUP BY c.id_concert, c.capacite
  HAVING SUM(b.nb_places) > c.capacite
);
-- Résultat : 16
-- (concerts 3, 5, 40, 60, 67, 69, 112, 144, 147, 177, 241, 341, 493,
--  494, 523, 793 ; dépassement de 1 à 3 places)

------------------------------------------------------------------------
-- C8 : nombre d'opérations groupées dont les opérations valides engagent
--      au moins deux sites
------------------------------------------------------------------------
SELECT COUNT(*) AS c8_groupes_multi_sites
FROM (
  SELECT b.id_billet_groupe
  FROM BILLET b
  JOIN CONCERT c ON c.id_concert = b.id_concert
  JOIN SCENE   s ON s.id_scene   = c.id_scene AND s.role = 'Site'
  WHERE b.id_billet_groupe IS NOT NULL
  GROUP BY b.id_billet_groupe
  HAVING COUNT(DISTINCT c.id_scene) >= 2
);
-- Résultat : 1 908   (sur 2 712 opérations groupées)

------------------------------------------------------------------------
-- C9 : nombre de places confirmées par catégorie de ressource
------------------------------------------------------------------------
SELECT c.categorie, SUM(b.nb_places) AS c9_places_confirmees
FROM CONCERT c
JOIN BILLET b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
GROUP BY c.categorie
ORDER BY c.categorie;
-- Résultat :
--   classique   193 724
--   jazz        160 350
--   rap         171 065
--   rock        172 909
--   électro     186 708


/* =====================================================================
   10 REQUÊTES MÉTIER
     jointure externe : Q1, Q2      HAVING : Q3
     sous-requête corrélée : Q4     division : Q5
     fonctions de fenêtrage : Q6, Q7, Q10
   ===================================================================== */

-- Q1. (jointure externe) Pour chaque scène, siège compris : nombre de
--     concerts, nombre de billets confirmés et chiffre d'affaires.
SELECT s.nom AS scene, s.role,
       COUNT(DISTINCT c.id_concert) AS nb_concerts,
       COUNT(b.id_billet)           AS nb_billets_confirmes,
       NVL(SUM(b.montant), 0)       AS chiffre_affaires
FROM SCENE s
LEFT JOIN CONCERT c ON c.id_scene   = s.id_scene
LEFT JOIN BILLET  b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
GROUP BY s.id_scene, s.nom, s.role
ORDER BY s.id_scene;
-- Résultat :
--   SCENE       ROLE   NB_CONCERTS  NB_BILLETS_CONFIRMES  CHIFFRE_AFFAIRES
--   Siège       Siège            0                     0              0,00
--   Scène Nord  Site           375               159 776     23 131 964,00
--   Scène Sud   Site           250               108 254     15 764 414,00
--   Scène Est   Site           191                86 893     12 372 109,00
-- La jointure externe garde le siège, qui n'a aucun concert.

-- Q2. (jointure externe) Nombre de spectateurs rattachés à chaque scène,
--     y compris les scènes sans spectateur rattaché.
SELECT s.nom AS scene, s.role,
       COUNT(r.id_personne) AS nb_spectateurs_rattaches
FROM SCENE s
LEFT JOIN RATTACHER r ON r.id_scene = s.id_scene
GROUP BY s.id_scene, s.nom, s.role
ORDER BY s.id_scene;
-- Résultat :
--   Siège       Siège       0
--   Scène Nord  Site    9 993
--   Scène Sud   Site    7 023
--   Scène Est   Site    4 856

-- Q3. (HAVING) Meilleurs clients : spectateurs ayant dépensé au moins
--     5 000 € en billets confirmés.
SELECT p.id_personne, p.nom, p.prenom,
       COUNT(*)         AS nb_billets,
       SUM(b.nb_places) AS nb_places,
       SUM(b.montant)   AS total_depense
FROM PERSONNE p
JOIN BILLET b ON b.id_spectateur = p.id_personne AND b.statut = 'PAYE'
GROUP BY p.id_personne, p.nom, p.prenom
HAVING SUM(b.montant) >= 5000
ORDER BY total_depense DESC;
-- Résultat : 9 spectateurs
--    7285  Chen      Paul    29 billets  90 places  5 648,00
--    8806  Thomas    Julia   33 billets  89 places  5 508,00
--   13092  Bonnet    Paul    32 billets  88 places  5 388,00
--    6485  Rousseau  Amine   32 billets  86 places  5 355,00
--    1788  Leroy     Eva     29 billets  85 places  5 275,00
--    8460  Guérin    Lucie   30 billets  92 places  5 203,00
--   10501  Faure     Amine   31 billets  93 places  5 197,00
--    6713  Leroy     Adam    29 billets  85 places  5 085,00
--   10869  Thomas    Louis   27 billets  76 places  5 022,00

-- Q4. (sous-requête corrélée) Pour chaque catégorie, le concert le mieux
--     rempli (places confirmées / capacité).
WITH remplissage AS (
  SELECT c.id_concert, c.libelle, c.categorie, c.capacite,
         NVL(SUM(b.nb_places), 0)              AS places_confirmees,
         NVL(SUM(b.nb_places), 0) / c.capacite AS taux
  FROM CONCERT c
  LEFT JOIN BILLET b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
  GROUP BY c.id_concert, c.libelle, c.categorie, c.capacite
)
SELECT r1.categorie, r1.libelle, r1.capacite, r1.places_confirmees,
       ROUND(100 * r1.taux, 1) AS taux_remplissage_pct
FROM remplissage r1
WHERE r1.taux = (SELECT MAX(r2.taux)
                 FROM remplissage r2
                 WHERE r2.categorie = r1.categorie)
ORDER BY r1.categorie;
-- Résultat :
--   classique  Concert classique 793  1 237  1 238  100,1
--   jazz       Concert jazz 3            737    739  100,3
--   rap        Concert rap 144         1 501  1 504  100,2
--   rock       Concert rock 494        2 466  2 469  100,1
--   électro    Concert électro 60        876    879  100,3
-- Le mieux rempli de chaque catégorie est en sur-réservation (cf. C7).

-- Q5. (division) Spectateurs ayant au moins un billet confirmé sur CHACUN
--     des sites : il n'existe aucun site où ils n'ont pas de billet confirmé.
SELECT p.id_personne, p.nom, p.prenom
FROM PERSONNE p
JOIN SPECTATEUR sp ON sp.id_personne = p.id_personne
WHERE NOT EXISTS (
  SELECT 1
  FROM SCENE s
  WHERE s.role = 'Site'
    AND NOT EXISTS (
      SELECT 1
      FROM BILLET b
      JOIN CONCERT c ON c.id_concert = b.id_concert
      WHERE b.id_spectateur = sp.id_personne
        AND b.statut = 'PAYE'
        AND c.id_scene = s.id_scene
    )
)
ORDER BY p.id_personne;
-- Résultat : 3 766 spectateurs. Les 10 premiers :
--    3 Vincent Lucie    5 Henry Gabriel    6 Rousseau Louise   7 Simon Hugo
--   15 Henry Yanis     17 Morel Paul      22 Haddad Mila      23 Dubois Léo
--   28 Michel Lucie    34 David Mehdi

-- Q6. (fenêtrage) Les 3 concerts au plus fort chiffre d'affaires de chaque site.
SELECT site, libelle, categorie, chiffre_affaires, rang
FROM (
  SELECT s.nom AS site, c.libelle, c.categorie,
         SUM(b.montant) AS chiffre_affaires,
         RANK() OVER (PARTITION BY s.id_scene ORDER BY SUM(b.montant) DESC) AS rang
  FROM SCENE s
  JOIN CONCERT c ON c.id_scene   = s.id_scene
  JOIN BILLET  b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
  GROUP BY s.id_scene, s.nom, c.id_concert, c.libelle, c.categorie
)
WHERE rang <= 3
ORDER BY site, rang;
-- Résultat :
--   Scène Est   Concert rap 92         rap        234 720,00  1
--   Scène Est   Concert rock 352       rock       203 405,00  2
--   Scène Est   Concert électro 449    électro    183 954,00  3
--   Scène Nord  Concert électro 670    électro    219 701,00  1
--   Scène Nord  Concert rock 433       rock       205 615,00  2
--   Scène Nord  Concert jazz 628       jazz       193 931,00  3
--   Scène Sud   Concert électro 687    électro    203 992,00  1
--   Scène Sud   Concert classique 400  classique  197 472,00  2
--   Scène Sud   Concert rock 372       rock       183 600,00  3

-- Q7. (fenêtrage) Chiffre d'affaires confirmé par trimestre et cumul.
SELECT TO_CHAR(date_billet, 'YYYY"-T"Q') AS trimestre,
       SUM(montant) AS ca_trimestre,
       SUM(SUM(montant)) OVER (ORDER BY TO_CHAR(date_billet, 'YYYY"-T"Q')) AS ca_cumule
FROM BILLET
WHERE statut = 'PAYE'
GROUP BY TO_CHAR(date_billet, 'YYYY"-T"Q')
ORDER BY trimestre;
-- Résultat :
--   2024-T4   1 855 351,00    1 855 351,00
--   2025-T1   5 211 899,00    7 067 250,00
--   2025-T2   6 624 278,00   13 691 528,00
--   2025-T3   6 839 446,00   20 530 974,00
--   2025-T4   6 567 013,00   27 097 987,00
--   2026-T1   6 871 065,00   33 969 052,00
--   2026-T2   5 450 186,00   39 419 238,00
--   2026-T3   6 521 928,00   45 941 166,00
--   2026-T4   5 327 321,00   51 268 487,00

-- Q8. Taux de remplissage moyen des concerts, par site et par catégorie.
SELECT s.nom AS site, r.categorie,
       COUNT(*) AS nb_concerts,
       ROUND(100 * AVG(r.taux), 1) AS remplissage_moyen_pct
FROM (
  SELECT c.id_concert, c.id_scene, c.categorie,
         NVL(SUM(b.nb_places), 0) / c.capacite AS taux
  FROM CONCERT c
  LEFT JOIN BILLET b ON b.id_concert = c.id_concert AND b.statut = 'PAYE'
  GROUP BY c.id_concert, c.id_scene, c.categorie, c.capacite
) r
JOIN SCENE s ON s.id_scene = r.id_scene
GROUP BY s.nom, r.categorie
ORDER BY s.nom, remplissage_moyen_pct DESC;
-- Résultat :
--   Scène Est   électro    44  65,8      Scène Nord  rock       60  63,7
--   Scène Est   jazz       27  65,3      Scène Nord  jazz       70  61,8
--   Scène Est   rap        39  61,6      Scène Nord  électro    90  61,1
--   Scène Est   classique  45  61,4      Scène Nord  classique  78  61,0
--   Scène Est   rock       36  58,8      Scène Nord  rap        77  56,5
--   Scène Sud   rock       52  61,2      Scène Sud   jazz       48  59,5
--   Scène Sud   rap        43  60,3      Scène Sud   électro    51  57,9
--   Scène Sud   classique  56  60,0

-- Q9. Taux d'annulation des opérations valides, par catégorie.
SELECT c.categorie,
       COUNT(*) AS nb_operations,
       SUM(CASE WHEN b.statut = 'ANNULE' THEN 1 ELSE 0 END) AS nb_annulees,
       ROUND(100 * SUM(CASE WHEN b.statut = 'ANNULE' THEN 1 ELSE 0 END) / COUNT(*), 2)
         AS taux_annulation_pct
FROM BILLET b
JOIN CONCERT c ON c.id_concert = b.id_concert
GROUP BY c.categorie
ORDER BY taux_annulation_pct DESC;
-- Résultat :
--   rock       74 948  5 866  7,83
--   classique  84 530  6 589  7,79
--   rap        74 940  5 799  7,74
--   jazz       69 445  5 287  7,61
--   électro    80 679  6 078  7,53

-- Q10. (fenêtrage) Les 5 jours les plus chargés et leur part dans
--      l'ensemble des opérations valides : mesure du pic de mise en vente.
SELECT jour, nb_operations, part_pct, rang
FROM (
  SELECT TRUNC(date_billet) AS jour,
         COUNT(*)           AS nb_operations,
         ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS part_pct,
         RANK() OVER (ORDER BY COUNT(*) DESC) AS rang
  FROM BILLET
  GROUP BY TRUNC(date_billet)
)
WHERE rang <= 5
ORDER BY rang;
-- Résultat :
--   2026-03-18  15 659  4,07  1
--   2026-11-02     784  0,20  2
--   2026-11-01     753  0,20  3
--   2025-10-15     747  0,19  4
--   2026-10-31     728  0,19  5
-- Le 18 mars 2026 concentre 20 fois plus d'opérations qu'un jour chargé.
