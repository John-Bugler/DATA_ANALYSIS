/* ============================================================
   VALUO — KROK 15: PŘÍZNAK SHODY VÝMĚRY

   Pouze pohledy, do dat nezasahuje.

   ------------------------------------------------------------
   NÁLEZ
   ------------------------------------------------------------
   U 4 195 parcel (3,1 %) se plocha spočítaná z geometrie liší
   od výměry v katastru o víc než 20 %. Odchylky tvoří
   U-křivku podle velikosti parcely:

       do 50 m2       15 834 parcel,  11,54 % odchylek
       50-200         16 200 parcel,   0,56 %
       200-1 000      70 140 parcel,   1,03 %
       1 000-5 000    27 872 parcel,   2,99 %
       nad 5 000       6 396 parcel,  11,35 %

   U malých parcel jde o přirozený jev — u parcely o 11 m2
   dělá chyba několika metrů desítky procent. U velkých bude
   příčinou složitý tvar nebo změna hranic v čase.

   Změna parcely po prodeji to nevysvětluje: u odchylek nad
   20 % je takových parcel 8,2 %, zatímco u shodných 14,8 %.

   ------------------------------------------------------------
   ZÁVĚR
   ------------------------------------------------------------
   Není to systematická chyba, kterou by šlo opravit jedním
   zásahem. Proto se odchylka označuje, ne opravuje.

   Pro posudek z toho plyne: výměru ber z katastru
   (areaValue_m2), ne z geometrie. Geometrie slouží
   k prostorovým dotazům, ne k měření.
   ============================================================ */

USE VALUO;
GO

/* ---------- 15.1 PŘÍZNAK U PARCEL -------------------------- */

CREATE OR ALTER VIEW dbo.v_KN_parcely
AS
SELECT  k.id,
        k.id_valuo,
        k.gml_id,
        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,
        k.parcel_number,
        k.areaValue_m2                          AS vymera_katastr_m2,
        CAST(k.geo_plocha.STArea() AS decimal(14,1))
                                                AS vymera_geometrie_m2,
        CAST(ABS(k.geo_plocha.STArea() - k.areaValue_m2)
             / NULLIF(k.areaValue_m2, 0) * 100
             AS decimal(8,2))                   AS odchylka_pct,
        CASE
            WHEN k.geo_plocha IS NULL           THEN N'bez geometrie'
            WHEN k.areaValue_m2 IS NULL
              OR k.areaValue_m2 = 0             THEN N'bez výměry'
            WHEN ABS(k.geo_plocha.STArea() - k.areaValue_m2)
                 / k.areaValue_m2 <= 0.05       THEN N'sedí'
            WHEN ABS(k.geo_plocha.STArea() - k.areaValue_m2)
                 / k.areaValue_m2 <= 0.20       THEN N'mírná odchylka'
            ELSE                                     N'NESEDÍ'
        END                                     AS shoda_vymery,
        k.beginLifespanVersion                  AS zapsano_od,
        CASE WHEN k.beginLifespanVersion > d.datum_zplatneni
             THEN N'ano' ELSE N'ne' END         AS zmenena_po_prodeji,
        k.refPoint_x,
        k.refPoint_y,
        k.refPoint_lon,
        k.refPoint_lat,
        k.geo_bod,
        k.geo_plocha,
        k.id_UP_FVU_data,
        u.fvu_kod,
        u.mira_vyuziti,
        u.podil_pct                             AS podil_v_ploche_pct
FROM dbo.KN_parcel_data k
LEFT JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
LEFT JOIN dbo.Valuo_data            d ON d.id     = k.id_valuo
LEFT JOIN dbo.KN_parcel_UP          u ON u.kn_id  = k.id AND u.poradi = 1;
GO


/* ---------- 15.2 SOUHRN ZA VKLAD ---------------------------
   Kolik parcel vkladu má nesedící výměru. Vstupuje do
   srovnávacího vzorku jako příznak kvality podkladu.        */

CREATE OR ALTER VIEW dbo.v_vklad_vymery
AS
SELECT  d.cislo_vkladu,
        COUNT(*)                                        AS parcel,
        SUM(CASE WHEN ABS(k.geo_plocha.STArea() - k.areaValue_m2)
                      / NULLIF(k.areaValue_m2, 0) > 0.20
                 THEN 1 ELSE 0 END)                     AS parcel_nesedi,
        SUM(CASE WHEN k.beginLifespanVersion > d.datum_zplatneni
                 THEN 1 ELSE 0 END)                     AS parcel_zmenenych
FROM dbo.KN_parcel_data k
JOIN dbo.Valuo_data     d ON d.id = k.id_valuo
WHERE k.geo_plocha IS NOT NULL
  AND k.areaValue_m2 > 0
GROUP BY d.cislo_vkladu;
GO


/* ---------- 15.3 KONTROLA ---------------------------------- */

SELECT shoda_vymery, COUNT(*) AS parcel
FROM dbo.v_KN_parcely
GROUP BY shoda_vymery
ORDER BY COUNT(*) DESC;
GO

SELECT  CASE WHEN parcel_nesedi = 0 THEN N'všechny parcely sedí'
             WHEN parcel_nesedi = parcel THEN N'žádná nesedí'
             ELSE N'část nesedí' END   AS stav,
        COUNT(*)                       AS vkladu
FROM dbo.v_vklad_vymery
GROUP BY CASE WHEN parcel_nesedi = 0 THEN N'všechny parcely sedí'
              WHEN parcel_nesedi = parcel THEN N'žádná nesedí'
              ELSE N'část nesedí' END
ORDER BY vkladu DESC;
GO
