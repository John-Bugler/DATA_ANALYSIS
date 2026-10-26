/* ============================================================
   VALUO — OPRAVA 12b: NÁPRAVA ZÁSAHU DO datum_podani

   Blok 12.4 předchozího skriptu prohodil den a měsíc u všech
   podání v dotčených dávkách, kde to šlo. Vycházel z domněnky,
   že parser v dávce prohodil všechno.

   Ta domněnka byla chybná. V dávce z 16. 9. 2026 byl prohozen
   jen zlomek záznamů a oprava zasáhla i ty správné:

       nelogické -> logické (opraveno)        1 459
       logické   -> NElogické (zkaženo)          52
       logické   -> logické (dopad neznámý)   1 745

   Ten třetí řádek je nejhorší: datum se změnilo a kontrolou
   prochází, ale správné být nemusí. Prohození 5. března na
   3. května projde, i když je chybné.

   ------------------------------------------------------------
   ŘEŠENÍ
   ------------------------------------------------------------
   Vrátit všechna podání do původního stavu a prohodit jen ta,
   která jsou prokazatelně vadná — tedy ta, kde podání vychází
   později než zplatnění, což je nemožné.

   Tím se opraví 1 459 doložitelných chyb a nezasáhne se do
   ničeho, o čem nic nevíme. Datum_zplatneni se nemění, to má
   kontrolu ve sloupci mesic a je opravené správně.
   ============================================================ */

USE VALUO;
GO

/* ---------- 12b.1 NÁVRAT PODÁNÍ DO PŮVODNÍHO STAVU --------- */

UPDATE v
SET v.datum_podani = z.podani_puvodni
FROM dbo.Valuo_data v
JOIN dbo.zaloha_datumy_20261022 z ON z.id = v.id
WHERE v.datum_podani <> z.podani_puvodni;
GO

SELECT @@ROWCOUNT AS vraceno_do_puvodniho_stavu;
GO

/* Kontrola: musí odpovídat stavu před krokem 12 */
SELECT SUM(CASE WHEN datum_podani > datum_zplatneni THEN 1 ELSE 0 END)
           AS nelogickych_pred_opravou
FROM dbo.Valuo_data;
GO


/* ---------- 12b.2 OPRAVA JEN PROKAZATELNĚ VADNÝCH ----------
   Prohodí se den a měsíc jen tam, kde podání vychází po
   zplatnění A kde je prohození vůbec možné (den i měsíc
   nejvýše 12).                                               */

UPDATE dbo.Valuo_data
SET datum_podani = DATETIMEFROMPARTS(
        YEAR(datum_podani),
        DAY(datum_podani),
        MONTH(datum_podani),
        DATEPART(hour,   datum_podani),
        DATEPART(minute, datum_podani),
        DATEPART(second, datum_podani),
        0)
WHERE datum_podani > datum_zplatneni
  AND DAY(datum_podani)   <= 12
  AND MONTH(datum_podani) <= 12;
GO

SELECT @@ROWCOUNT AS opraveno;
GO


/* ---------- 12b.3 KONTROLA --------------------------------- */

SELECT  COUNT(*)                                        AS zaznamu,
        SUM(CASE WHEN MONTH(datum_zplatneni) <> mesic
                 THEN 1 ELSE 0 END)                     AS mesic_nesedi,
        SUM(CASE WHEN datum_podani > datum_zplatneni
                 THEN 1 ELSE 0 END)                     AS podani_po_zplatneni,
        SUM(CASE WHEN datum_podani <> (SELECT z.podani_puvodni
                                       FROM dbo.zaloha_datumy_20261022 z
                                       WHERE z.id = v.id)
                 THEN 1 ELSE 0 END)                     AS zmenenych_proti_originalu
FROM dbo.Valuo_data v;
GO

/* Očekávání:
     mesic_nesedi                0
     podani_po_zplatneni         malý zbytek, kde prohození nešlo
     zmenenych_proti_originalu   okolo 1 459                     */


/* ---------- 12b.4 CO ZŮSTÁVÁ NEJISTÉ -----------------------
   Záznamy z dotčených dávek, kde je prohození možné, ale
   nelze ho doložit. Mohou být prohozené a my to nepoznáme.
   Pouze ČTE — je to podklad, ne oprava.                      */

SELECT  CAST([timestamp] AS date)   AS import,
        COUNT(*)                    AS celkem_v_davce,
        SUM(CASE WHEN DAY(datum_podani) <= 12
                  AND MONTH(datum_podani) <= 12
                 THEN 1 ELSE 0 END) AS podani_nerozlisitelnych
FROM dbo.Valuo_data
WHERE CAST([timestamp] AS date) IN (
        SELECT DISTINCT CAST(z.import AS date)
        FROM dbo.zaloha_datumy_20261022 z
        WHERE MONTH(z.zplatneni_puvodni) <> z.mesic
)
GROUP BY CAST([timestamp] AS date)
ORDER BY import;
GO
