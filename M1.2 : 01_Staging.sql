/* =====================================================================
   FESTIVAL DE MUSIQUE — 01 : tables d'import (staging)
   Oracle — à exécuter APRÈS ton script de création des tables, avec F5.

   Ensuite, importer chaque CSV dans sa table STG_ :
     clic droit sur la table > Importer des données >
       - fichier : le CSV, encodage UTF-8, séparateur virgule
       - « En-tête » coché
       - méthode : Insérer
     scenes.csv      -> STG_SCENES
     spectateurs.csv -> STG_SPECTATEURS
     concerts.csv    -> STG_CONCERTS
     billets.csv     -> STG_BILLETS   (385 149 lignes : patienter)

   Toutes les colonnes sont en texte : les valeurs défectueuses sont
   acceptées à l'import, et traitées ensuite par 02_chargement.sql.
   ===================================================================== */

BEGIN
  FOR t IN (SELECT table_name FROM user_tables
            WHERE table_name IN ('STG_SCENES','STG_SPECTATEURS',
                                 'STG_CONCERTS','STG_BILLETS')) LOOP
    EXECUTE IMMEDIATE 'DROP TABLE "' || t.table_name || '" PURGE';
  END LOOP;
END;
/

CREATE TABLE STG_SCENES (
  id_scene  VARCHAR2(100),
  nom       VARCHAR2(300),
  ville     VARCHAR2(300),
  role      VARCHAR2(100)
);

CREATE TABLE STG_SPECTATEURS (
  id_spectateur     VARCHAR2(100),
  nom               VARCHAR2(300),
  prenom            VARCHAR2(300),
  email             VARCHAR2(500),
  telephone         VARCHAR2(100),
  ville             VARCHAR2(300),
  id_scene          VARCHAR2(100),
  date_inscription  VARCHAR2(100)
);

CREATE TABLE STG_CONCERTS (
  id_concert     VARCHAR2(100),
  libelle        VARCHAR2(500),
  categorie      VARCHAR2(200),
  id_scene       VARCHAR2(100),
  debut          VARCHAR2(100),
  duree_minutes  VARCHAR2(100),
  capacite       VARCHAR2(100),
  prix_unitaire  VARCHAR2(100)
);

CREATE TABLE STG_BILLETS (
  id_billet      VARCHAR2(100),
  id_spectateur  VARCHAR2(100),
  id_concert     VARCHAR2(100),
  date_billet    VARCHAR2(100),
  nb_places      VARCHAR2(100),
  montant        VARCHAR2(100),
  statut         VARCHAR2(100),
  id_groupe      VARCHAR2(100)
);
