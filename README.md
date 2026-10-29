PROJET DATA STORAGE SYSTEMS — FESTIVAL DE MUSIQUE SUR TROIS SCÈNES
Groupe 04 · SGBD : Oracle (SQL Developer)
=====================================================================

1. CONTENU
---------------------------------------------------------------------
  creation_tables.sql          création des tables du modèle
                               (PERSONNE, SPECTATEUR, ARTISTE, SCENE,
                               CONCERT, BILLET, RATTACHER, JOUER)
  01_staging.sql               tables d'import STG_* (tout en texte)
  02_chargement.sql            chargement des CSV et traitement des défauts
  03_controles_requetes.sql    valeurs de contrôle C1 à C9 et 10 requêtes
                               métier, résultats en commentaire
  04_donnees_artistes.sql      jeu de données fictif pour ARTISTE et JOUER
  scenes.csv, spectateurs.csv, concerts.csv, billets.csv   données sources


2. ORDRE D'EXÉCUTION
---------------------------------------------------------------------
Chaque script s'exécute dans SQL Developer avec F5 (« Exécuter le script »).

  1) creation_tables.sql
  2) 01_staging.sql
  3) Import des CSV : dans le panneau Connexions > Tables (actualiser),
     clic droit sur la table > Importer des données
       - encodage UTF-8, séparateur virgule, « En-tête » coché
       - méthode : Insérer
         scenes.csv      -> STG_SCENES
         spectateurs.csv -> STG_SPECTATEURS
         concerts.csv    -> STG_CONCERTS
         billets.csv     -> STG_BILLETS (385 149 lignes, quelques minutes)
  4) 02_chargement.sql
  5) 03_controles_requetes.sql
  6) 04_donnees_artistes.sql (facultatif)

Les scripts 02 et 04 sont ré-exécutables : ils vident d'abord les
données qu'ils chargent.


3. PRINCIPE DU CHARGEMENT
---------------------------------------------------------------------
  - Les CSV sont importés tels quels dans les tables STG_*, dont toutes
    les colonnes sont en texte : aucune valeur défectueuse ne bloque
    l'import.
  - 02_chargement.sql convertit les valeurs avec des fonctions qui
    renvoient NULL au lieu de planter (f_int, f_num, f_date), détecte
    les défauts, puis insère seulement les lignes valides.
  - Chaque défaut est tracé dans la table ANOMALIE (table d'origine,
    identifiant, motif, traitement, détail). Traitements possibles :
      CORRIGEE   la ligne est chargée après correction
      FUSIONNEE  doublon de personne, ses billets sont réaffectés
      REJETEE    la ligne n'est pas chargée (opération non valide)
  - Index créés sur les clés étrangères de BILLET et CONCERT (Oracle ne
    les crée pas automatiquement).


4. DÉFAUTS DÉTECTÉS ET TRAITEMENT
---------------------------------------------------------------------
scenes.csv
  - Nom « Site Scène Nord/Sud/Est » au lieu de « Scène Nord/Sud/Est »
    (refusé par CK_SCENE_NOM)                         -> CORRIGEE (3)
  - Rôle en minuscules « site », « siège »
    (refusé par CK_SCENE_ROLE)                        -> CORRIGEE (4)

spectateurs.csv
  - 90 personnes saisies deux fois : même e-mail une fois normalisé
    (minuscules, sans espaces), mêmes nom, prénom, téléphone, site.
    On garde le plus petit identifiant ; les 813 billets passés sous
    l'autre identifiant lui sont rattachés              -> FUSIONNEE (90)
  - 23 spectateurs sans e-mail : pas un défaut, chaque ligne reste une
    personne distincte.

billets.csv (607 opérations non valides)
  - Ressource inexistante : id_concert absent de
    concerts.csv                                        -> REJETEE (400)
  - Date de l'opération après le début du concert       -> REJETEE (96)
  - Montant négatif (refusé par CK_BILLET_MONTANT)      -> REJETEE (64)
  - Opération enregistrée deux fois à l'identique (seul id_billet
    change), surtout pendant le pic de mise en vente.
    On garde le premier id_billet                       -> REJETEE (47)

Signalés mais conservés (pas des erreurs de saisie)
  - 16 concerts en sur-réservation de 1 à 3 places : impossible de
    savoir quelle opération retirer ; mesuré par C7.
  - Concerts qui se chevauchent sur une même scène : listés à la fin
    de 02_chargement.sql.

Contrôlés sans défaut trouvé : identifiants non numériques, dates
impossibles, montant différent de places x prix, nombre de places hors
1..10, statut inconnu, usager inexistant.


5. HYPOTHÈSES ET CORRESPONDANCES
---------------------------------------------------------------------
  personne / usager      SPECTATEUR (sous-type de PERSONNE)
  opération              BILLET
  ressource              CONCERT
  site                   SCENE de rôle 'Site' (le siège n'est pas un site)
  site d'une opération   scène de son concert
  opération valide       billet chargé dans BILLET, payé ou annulé
  opération confirmée    statut CONFIRMEE dans le CSV -> 'PAYE'
                         (ANNULEE -> 'ANNULE')
  opération groupée      billets ayant le même id_groupe dans le CSV.
                         Dans le modèle, l'association réflexive
                         BILLET.id_billet_groupe relie chaque billet du
                         groupe au plus petit id_billet valide du groupe.


6. VALEURS DE CONTRÔLE
---------------------------------------------------------------------
  C1  personnes distinctes                         21 872
  C2  opérations non valides                       607
        ressource inexistante 400 · date après le début 96
        montant négatif 64 · opération en double 47
  C3  opérations valides confirmées                354 923
  C4  jour le plus chargé                          2026-03-18 : 15 659
  C5  chiffre d'affaires par site                  Scène Nord 23 131 964,00
                                                   Scène Sud  15 764 414,00
                                                   Scène Est  12 372 109,00
  C6  personnes actives sur au moins deux sites    13 016
  C7  ressources en sur-réservation                16
  C8  opérations groupées sur au moins deux sites  1 908
  C9  places confirmées par catégorie              classique 193 724
                                                   électro   186 708
                                                   rock      172 909
                                                   rap       171 065
                                                   jazz      160 350

Si seules les opérations confirmées comptaient comme « valides », C6
vaudrait 12 477 (C4 et C8 ne changent pas).


7. REQUÊTES MÉTIER (03_controles_requetes.sql)
---------------------------------------------------------------------
  Q1   CA, concerts et billets par scène, siège compris   jointure externe
  Q2   spectateurs rattachés à chaque scène               jointure externe
  Q3   spectateurs ayant dépensé au moins 5 000 €         HAVING
  Q4   concert le mieux rempli de chaque catégorie        sous-requête corrélée
  Q5   spectateurs ayant un billet confirmé sur
       tous les sites (3 766)                             division
  Q6   3 meilleurs concerts par CA dans chaque site       fenêtrage (RANK)
  Q7   CA par trimestre et cumul                          fenêtrage (SUM OVER)
  Q8   taux de remplissage moyen par site et catégorie
  Q9   taux d'annulation par catégorie
  Q10  5 jours les plus chargés et part du total
       (pic de mise en vente)                             fenêtrage


8. DONNÉES ARTISTES (04_donnees_artistes.sql)
---------------------------------------------------------------------
Les CSV ne contiennent pas d'artistes. Le script ajoute un jeu de
données fictif :
  - 30 artistes, 6 par genre, identifiants 100001 à 100030 dans PERSONNE
    (pour ne pas croiser les spectateurs, identifiants 1 à 21 962)
  - 1 632 passages dans JOUER : 1 à 3 artistes du même genre par
    concert ; le dernier à passer est la tête d'affiche, au plus gros
    cachet.
5 artistes se retrouvent sur deux concerts qui se chevauchent : ce sont
les concerts déjà en chevauchement dans concerts.csv.


9. VÉRIFICATION DES RÉSULTATS
---------------------------------------------------------------------
Les valeurs de contrôle et les résultats des requêtes ont été obtenus
en rejouant le même traitement sur une copie de la base, puis vérifiés
par un second calcul indépendant : les deux donnent les mêmes chiffres.
