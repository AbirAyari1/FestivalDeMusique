/* =====================================================================
   FESTIVAL DE MUSIQUE - L4 : anomalie de concurrence, SESSION B
   ===================================================================== */

-- B0 · affichage DBMS_OUTPUT et vérification 
SET SERVEROUTPUT ON;

SELECT PKG_FORFAIT.places_restantes(900001) AS places_restantes_900001 FROM dual;



/* =====================================================================
   PARTIE 1 · L'ANOMALIE (procédure sans verrou)
   ===================================================================== */

-- B1 · (après A1) B achète 6 places pendant que l'achat de A n'est pas
--      validé. B ne voit pas les 6 places de A : il compte 10 restantes.
DECLARE
  v_tete NUMBER;
BEGIN
  DBMS_OUTPUT.PUT_LINE('B1 : places restantes vues par B avant achat : '
                       || PKG_FORFAIT.places_restantes(900001));
  PKG_FORFAIT.acheter_forfait_sans_verrou(900002,
    T_FORFAIT(T_LIGNE_FORFAIT(900001, 6)), v_tete);
  DBMS_OUTPUT.PUT_LINE('B1 : achat de 6 places accepté, billet ' || v_tete);
END;
/
-- -> revenir en session A : étape A2

-- B2 · (après A2) B valide à son tour 
COMMIT;
-- -> revenir en session A : étape A3 (constat de la sur-réservation)


/* =====================================================================
   PARTIE 2 · LA CORRECTION (procédure avec verrou)
   ===================================================================== */

-- B3 · (après A5) B achète 6 places avec la procédure corrigée.
--      B reste BLOQUÉE sur le verrou de la ligne CONCERT 900001 tant que
--      A n'a pas validé. Revenir en session A (étapes A6 puis A7).
DECLARE
  v_tete NUMBER;
BEGIN
  PKG_FORFAIT.acheter_forfait(900002,
    T_FORFAIT(T_LIGNE_FORFAIT(900001, 6)), v_tete);
  DBMS_OUTPUT.PUT_LINE('B3 : achat de 6 places accepté, billet ' || v_tete);
END;
/

-- B4 · B termine sa transaction (rien à valider : l'achat a été refusé) ----
ROLLBACK;
-- -> revenir en session A : étape A8
