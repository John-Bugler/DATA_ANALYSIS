/* ================================================================
   VALUO — KROK 30b: ODSTRANĚNÍ 8 STARÝCH DUPLICIT (typ B)

   Tatáž položka vkladu (shodný vklad, druh, typ, adresa, číslo
   jednotky i popis) přišla ze dvou dřívějších importů s jinou
   plochou. Nalezeno klíčem totožnosti z kroku 30, schváleno znalcem
   24. 10. 2026.

   Ponechává se řádek s podlahovou plochou (6 rodinných domů:
   Ruzyně ×5, Průhonice); u garáže a bytu novější řádek.

     smazat  vklad              typ          plocha  typ plochy
     116990  V-10105/2025-210   rodinný dům      81  Výměra parcely
     118622  V-34546/2024-101   rodinný dům     282  Výměra parcely
     118623  V-38903/2024-101   rodinný dům     107  Výměra parcely
     118673  V-44657/2024-101   rodinný dům     183  Výměra parcely
     118748  V-49916/2024-101   rodinný dům     177  Výměra parcely
     118738  V-51551/2024-101   rodinný dům     273  Výměra parcely
      28108  V-16024/2024-101   garáž             0  —
      11307  V-706/2024-202     byt             663  Výměra parcely

   Dvojice typu A (budova + pozemek pod ní, oba jako „budova",
   25 vkladů) se NEMAŽOU — nejsou to duplicity.

   PO NĚM: python 30_import_valuo.py --prepocty
   ================================================================ */

SET NOCOUNT ON;

SELECT * INTO dbo.zaloha_30b_valuo FROM (
    SELECT * FROM dbo.Valuo_data
    WHERE id IN (116990, 118622, 118623, 118673, 118748, 118738, 28108, 11307)
    UNION ALL SELECT * FROM dbo.Valuo_data WHERE 1 = 0) q;

SELECT * INTO dbo.zaloha_30b_kn_parcel FROM (
    SELECT * FROM dbo.KN_parcel_data
    WHERE id_valuo IN (116990, 118622, 118623, 118673, 118748, 118738, 28108, 11307)
    UNION ALL SELECT * FROM dbo.KN_parcel_data WHERE 1 = 0) q;
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;

DELETE u FROM dbo.KN_parcel_UP u JOIN dbo.KN_parcel_data k ON k.id = u.kn_id
WHERE k.id_valuo IN (116990, 118622, 118623, 118673, 118748, 118738, 28108, 11307);

DELETE s FROM dbo.KN_parcel_UP_stav s JOIN dbo.KN_parcel_data k ON k.id = s.kn_id
WHERE k.id_valuo IN (116990, 118622, 118623, 118673, 118748, 118738, 28108, 11307);

DELETE FROM dbo.KN_parcel_data
WHERE id_valuo IN (116990, 118622, 118623, 118673, 118748, 118738, 28108, 11307);

DELETE FROM dbo.KN_k_pretazeni
WHERE id_valuo IN (116990, 118622, 118623, 118673, 118748, 118738, 28108, 11307);

DELETE FROM dbo.Valuo_data
WHERE id IN (116990, 118622, 118623, 118673, 118748, 118738, 28108, 11307);

COMMIT;
GO
