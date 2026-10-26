/* ================================================================
   VALUO — KROK 30a: ODSTRANĚNÍ DUPLICIT Z RANNÍHO IMPORTU 24. 10. 2026

   CO SE STALO
   První běh 30_import_valuo.py (verze 30.0, 24. 10. 2026 09:47–09:48)
   vložil 862 řádků. VŠECHNY jsou duplicity existujících záznamů —
   tytéž nemovitosti v jiné podobě, kterou unikátní klíč
   (cislo_vkladu, adresa, nemovitost, typ, plocha) nezachytil:

     851  plocha 0 ve starých datech × NULL v novém importu
      12  tatáž jednotka (shodné číslo i popis), Valuo uvedlo v jiném
          balíčku jinou plochu (např. 53,6 × 536, 69 × 357)
     ~30  tatáž budova, Valuo mezitím změnilo formát popisu
          („č. 1353/2 Chodov" × „č.p. 2349, ..., na parcele 1353/2")

   Ověřeno klíčem (vklad, druh, typ, adresa, číslo jednotky): každý
   z 862 řádků má ve starých datech dvojníka. Druhá dávka (43 balíčků,
   id 120501–122859) nemá ani jednu kolizi a zůstává.

   Dopad: ~673 starých vkladů spadlo do „nelze porovnat", protože
   měly nemovitost dvakrát.

   CO SKRIPT DĚLÁ
   1) zálohuje všechny dotčené řádky
   2) v jedné transakci smaže řádky id 119639–120500 a vše navázané
      (parcely, zatřídění do ÚP, evidence ÚP, fronta katastru)
   3) evidence souborů zůstává — soubory jsou zpracované, jejich
      obsah v databázi je (jako staré řádky); jen se vynuluje počet
      vložených, který byl nepravdivý

   PO NĚM
   python 30_import_valuo.py --prepocty   (verze 30.2)
   ================================================================ */

SET NOCOUNT ON;

/* ---------- 30a.1 KONTROLA ROZSAHU -------------------------------
   Musí vyjít: radku 862, od 2026-10-24 09:47, do 09:48,
   s_dvojnikem 862. Jinak NEPOKRAČOVAT.                            */

SELECT COUNT(*) AS radku, MIN([timestamp]) AS od, MAX([timestamp]) AS do,
       SUM(CASE WHEN EXISTS (
            SELECT 1 FROM dbo.Valuo_data s WHERE s.id < 119639
              AND s.cislo_vkladu = d.cislo_vkladu AND s.nemovitost = d.nemovitost
              AND s.typ = d.typ AND s.adresa = d.adresa
              AND ISNULL(s.jednotka_oznaceni, N'') = ISNULL(d.jednotka_oznaceni, N''))
           THEN 1 ELSE 0 END) AS s_dvojnikem
FROM dbo.Valuo_data d
WHERE d.id BETWEEN 119639 AND 120500;
GO

/* ---------- 30a.2 ZÁLOHY -----------------------------------------
   UNION ALL s prázdným selectem, aby se nezkopírovala vlastnost
   IDENTITY (poučení v DB_VALUO_stav.md).                          */

SELECT * INTO dbo.zaloha_30a_valuo FROM (
    SELECT * FROM dbo.Valuo_data WHERE id BETWEEN 119639 AND 120500
    UNION ALL SELECT * FROM dbo.Valuo_data WHERE 1 = 0) q;

SELECT * INTO dbo.zaloha_30a_kn_parcel FROM (
    SELECT * FROM dbo.KN_parcel_data WHERE id_valuo BETWEEN 119639 AND 120500
    UNION ALL SELECT * FROM dbo.KN_parcel_data WHERE 1 = 0) q;

SELECT u.* INTO dbo.zaloha_30a_kn_up
FROM dbo.KN_parcel_UP u JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
WHERE k.id_valuo BETWEEN 119639 AND 120500;

SELECT s.* INTO dbo.zaloha_30a_up_stav
FROM dbo.KN_parcel_UP_stav s JOIN dbo.KN_parcel_data k ON k.id = s.kn_id
WHERE k.id_valuo BETWEEN 119639 AND 120500;

SELECT * INTO dbo.zaloha_30a_fronta
FROM dbo.KN_k_pretazeni WHERE id_valuo BETWEEN 119639 AND 120500;

SELECT (SELECT COUNT(*) FROM dbo.zaloha_30a_valuo)     AS valuo,      -- 862
       (SELECT COUNT(*) FROM dbo.zaloha_30a_kn_parcel) AS parcel,     -- 938
       (SELECT COUNT(*) FROM dbo.zaloha_30a_kn_up)     AS up_vazeb,   -- 847
       (SELECT COUNT(*) FROM dbo.zaloha_30a_up_stav)   AS up_stav,    -- 762
       (SELECT COUNT(*) FROM dbo.zaloha_30a_fronta)    AS fronta;     -- 862
GO

/* ---------- 30a.3 SMAZÁNÍ ---------------------------------------- */

BEGIN TRANSACTION;

DELETE u FROM dbo.KN_parcel_UP u
JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
WHERE k.id_valuo BETWEEN 119639 AND 120500;

DELETE s FROM dbo.KN_parcel_UP_stav s
JOIN dbo.KN_parcel_data k ON k.id = s.kn_id
WHERE k.id_valuo BETWEEN 119639 AND 120500;

DELETE FROM dbo.KN_parcel_data  WHERE id_valuo BETWEEN 119639 AND 120500;
DELETE FROM dbo.KN_k_pretazeni  WHERE id_valuo BETWEEN 119639 AND 120500;
DELETE FROM dbo.Valuo_data      WHERE id       BETWEEN 119639 AND 120500;

UPDATE dbo.Valuo_soubory SET vlozeno = 0
WHERE nacteno < '2026-10-24 10:00';

/* kontrola uvnitř transakce: všechno 0 */
SELECT (SELECT COUNT(*) FROM dbo.Valuo_data     WHERE id       BETWEEN 119639 AND 120500) AS valuo,
       (SELECT COUNT(*) FROM dbo.KN_parcel_data WHERE id_valuo BETWEEN 119639 AND 120500) AS parcel,
       (SELECT COUNT(*) FROM dbo.KN_k_pretazeni WHERE id_valuo BETWEEN 119639 AND 120500) AS fronta,
       (SELECT COUNT(*) FROM dbo.KN_parcel_UP u
        LEFT JOIN dbo.KN_parcel_data k ON k.id = u.kn_id WHERE k.id IS NULL)              AS osirele_up;

COMMIT;
GO

/* ---------- 30a.4 STAV PO ----------------------------------------
   Čeká se: radku 110 624 − 862 = 109 762, kolizí 7 (jen známé
   staré skupiny).                                                 */

SELECT (SELECT COUNT(*) FROM dbo.Valuo_data) AS radku,
       (SELECT COUNT(DISTINCT cislo_vkladu) FROM dbo.Valuo_data) AS vkladu,
       (SELECT COUNT(*) FROM (
            SELECT 1 AS x FROM dbo.Valuo_data
            GROUP BY cislo_vkladu, nemovitost, typ, adresa,
                     ISNULL(jednotka_oznaceni, N''),
                     CASE WHEN adresa = N'Neznámá adresa' THEN popis ELSE '' END
            HAVING COUNT(*) > 1) g) AS kolizi;
GO
