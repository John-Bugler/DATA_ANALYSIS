/* ============================================================
   VALUO — KROK 24e: OPRAVA PŘIŘAZENÍ ÚZEMNÍHO PLÁNU

   PŘED SPUŠTĚNÍM ZÁLOHUJ DATABÁZI.
   Mění pohled v_vklad_UP a uklízí starý sloupec. Ovlivní
   cenové hladiny pozemků v Praze.

   ============================================================
   CO BYLO ŠPATNĚ
   ============================================================
   Vklad V-5007/2025-208 má 101 parcel ve třech středočeských
   katastrálních územích (Kluk, Poděbrady, Sokoleč) a ani jedna
   nemá záznam v KN_parcel_UP. Přesto v_vklad_UP vracel:

       cislo_vkladu       fvu_kod   mira_vyuziti
       V-5007/2025-208    OB        NO_DATA

   Kluk je od Prahy padesát kilometrů a územní plán Prahy tam
   neplatí.

   ------------------------------------------------------------
   PŘÍČINA
   ------------------------------------------------------------
   V databázi jsou DVĚ různá přiřazení územního plánu:

       KN_parcel_data.id_UP_FVU_data   starší sloupec, jeden
                                       polygon na parcelu
       KN_parcel_UP                    tabulka z kroku 09, vazba
                                       M:N s podíly ploch a
                                       pořadím

   Pohled v_vklad_UP četl ze starého sloupce:

       JOIN dbo.UP_FVU_data u ON u.id = k.id_UP_FVU_data

   A ten je zasolený — obsahuje pražské funkční využití i
   u parcel mimo Prahu:

   | kraj               | parcel  | starý sloupec | KN_parcel_UP |
   |--------------------|---------|---------------|--------------|
   | Hlavní město Praha | 122 939 |       122 937 |      122 933 |
   | Středočeský        |  13 120 |           712 |            0 |
   | Ústecký            |   1 373 |           242 |            0 |
   | Plzeňský           |   2 297 |           189 |            0 |
   | Jihomoravský       |   2 842 |           174 |            0 |
   | ostatní kraje      |       - |           252 |            0 |

   Mimo Prahu je takto označeno 1 569 parcel. Novější tabulka
   KN_parcel_UP je přitom v pořádku a obsahuje jen Prahu.

   ------------------------------------------------------------
   CO SE OPRAVUJE
   ------------------------------------------------------------
   1  v_vklad_UP čte z KN_parcel_UP. Logika zůstává stejná —
      bere se funkční využití největší parcely vkladu, uvnitř
      parcely pak polygon s největším podílem plochy (poradi=1).

   2  Starý sloupec id_UP_FVU_data se vynuluje u parcel mimo
      Prahu. Sloupec zůstává, pro případ že na něm visí něco
      dalšího.

   ------------------------------------------------------------
   CO SE TÍM ZMĚNÍ
   ------------------------------------------------------------
   v_cenove_hladiny bere pro pozemky klíč FVU z téhož pohledu,
   takže se opraví i cenové hladiny, ne jen prahy. Vklady mimo
   Prahu se přesunou z klíče FVU: na DRUH:, kam patří.
   ============================================================ */

USE VALUO;
GO

/* ---------- 24e.1 STAV PŘED ------------------------------- */

SELECT  stav = N'před opravou',
        vkladu_s_FVU = COUNT(*),
        mimo_Prahu = SUM(CASE WHEN c.kraj_nazev <> N'Hlavní město Praha'
                              THEN 1 ELSE 0 END)
FROM dbo.v_vklad_UP u
JOIN dbo.Valuo_data v ON v.cislo_vkladu = u.cislo_vkladu
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
WHERE u.fvu_kod IS NOT NULL;
GO


/* ---------- 24e.2 OPRAVENÝ POHLED --------------------------
   Logika beze změny, jen správný zdroj. KN_parcel_UP má vazbu
   M:N, proto se uvnitř parcely bere polygon s pořadím 1, tedy
   s největším podílem plochy.                                */

CREATE OR ALTER VIEW dbo.v_vklad_UP
AS
WITH hlavni_parcela AS (
    SELECT  k.id_valuo,
            u.fvu_kod,
            u.mira_vyuziti,
            ROW_NUMBER() OVER (PARTITION BY k.id_valuo
                               ORDER BY k.areaValue_m2 DESC, k.id) AS poradi
    FROM dbo.KN_parcel_data k
    JOIN dbo.KN_parcel_UP  u ON u.kn_id = k.id AND u.poradi = 1
)
SELECT  v.cislo_vkladu,
        MIN(h.fvu_kod)      AS fvu_kod,
        MIN(h.mira_vyuziti) AS mira_vyuziti
FROM dbo.Valuo_data v
JOIN hlavni_parcela h ON h.id_valuo = v.id AND h.poradi = 1
GROUP BY v.cislo_vkladu;
GO


/* ---------- 24e.3 KONTROLA POHLEDU ------------------------- */

SELECT  stav = N'po opravě',
        vkladu_s_FVU = COUNT(*),
        mimo_Prahu = SUM(CASE WHEN c.kraj_nazev <> N'Hlavní město Praha'
                              THEN 1 ELSE 0 END)
FROM dbo.v_vklad_UP u
JOIN dbo.Valuo_data v ON v.cislo_vkladu = u.cislo_vkladu
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = v.kod_ku
WHERE u.fvu_kod IS NOT NULL;
GO

/* Doložený případ — nemá vracet nic */
SELECT N'V-5007/2025-208 (Kluk, 101 parcel)' AS vklad, *
FROM dbo.v_vklad_UP WHERE cislo_vkladu = 'V-5007/2025-208';
GO


/* ---------- 24e.4 ÚKLID STARÉHO SLOUPCE --------------------
   Vynuluje se jen mimo Prahu. V Praze zůstává, protože na něm
   může viset něco dalšího.                                   */

UPDATE p SET p.id_UP_FVU_data = NULL
FROM dbo.KN_parcel_data p
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = p.kod_ku
WHERE c.kraj_nazev <> N'Hlavní město Praha'
  AND p.id_UP_FVU_data IS NOT NULL;
GO

PRINT N'vynulováno parcel mimo Prahu: ' + CAST(@@ROWCOUNT AS varchar);
GO

SELECT  kraj = c.kraj_nazev,
        se_starym_sloupcem = COUNT(*)
FROM dbo.KN_parcel_data p
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = p.kod_ku
WHERE p.id_UP_FVU_data IS NOT NULL
GROUP BY c.kraj_nazev ORDER BY COUNT(*) DESC;
GO


/* ---------- 24e.5 PŘEPOČET PRAHŮ --------------------------- */

EXEC dbo.sp_prepocet_prahu;
GO

/* Funkční využití už smí být jen v Praze */
SELECT uzemi, COUNT(*) AS kombinaci, SUM(n) AS vkladu
FROM dbo.Valuo_prahy WHERE klic LIKE N'FVU:%'
GROUP BY uzemi;
GO

/* Pozemky v Praze po všech opravách */
SELECT  co      = N'POZEMEK PRAHA, Kč/m²',
        skupina = LEFT(REPLACE(klic, N'FVU:', N''),
                       CHARINDEX(N'|', REPLACE(klic, N'FVU:', N'')) - 1),
        vymera  = SUBSTRING(klic, CHARINDEX(N'|', klic) + 1, 20),
        vzorku  = n,
        median  = CAST(median AS decimal(12,0)),
        zdola   = CAST(prah_dolni AS decimal(12,0)),
        shora   = CAST(prah_horni AS decimal(12,0)),
        rozptyl = sigma
FROM dbo.Valuo_prahy
WHERE klic LIKE N'FVU:%'
ORDER BY skupina, vymera;
GO

/* Cenové hladiny pozemků se opravily taky — kolik jich je
   podle FVU a kolik podle druhu                             */
SELECT  klic_typ = CASE WHEN klic LIKE N'FVU:%' THEN N'podle FVU'
                        ELSE N'podle druhu' END,
        uroven, kombinaci = COUNT(*), bodu = SUM(bodu)
FROM dbo.v_cenove_hladiny
WHERE klasifikace = 'JC_PARCELY'
GROUP BY CASE WHEN klic LIKE N'FVU:%' THEN N'podle FVU'
              ELSE N'podle druhu' END, uroven
ORDER BY klic_typ, uroven;
GO
