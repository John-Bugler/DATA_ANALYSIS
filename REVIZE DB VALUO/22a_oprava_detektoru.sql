/* ============================================================
   VALUO — KROK 22a: OPRAVA DETEKTORU ODDĚLENÉHO VLASTNICTVÍ

   Jen pohledy, do dat nezasahuje. Spusť celé najednou.
   Nahrazuje logiku z kroku 22, která byla chybná.

   ============================================================
   CO BYLO V KROKU 22 ŠPATNĚ
   ============================================================
   Krok 22 označil za oddělené vlastnictví každý vklad, v němž
   se parcela uvedená v popisu budovy neprodávala. Označil tak
   3 702 z 5 507 vkladů, tedy 67 % — a mezi nimi běžné prodeje
   domu se zahradou:

   | vklad            | parcela budovy  | prodávaná parcela |
   |------------------|-----------------|-------------------|
   | V-10068/2024-209 | 1829 Úvaly      | 1830 Úvaly        |
   | V-10135/2024-101 | 962/2 Smíchov   | 962/1 Smíchov     |
   | V-10198/2025-101 | 1298 Libeň      | 1299 Libeň        |

   Chyba v úvaze: je-li stavba součástí pozemku, není ten
   pozemek samostatnou nemovitostí — prodává se jako jedna věc
   s budovou a jako samostatná parcela se ve vkladu vůbec
   neuvádí. Samostatně se uvádí jen zahrada. To, že parcela pod
   stavbou chybí mezi prodávanými, je tedy u domů normální stav.

   Následek: u rodinných domů zbyla jediná hladina na úrovni
   katastrálního území (Štěrboholy, 11 bodů).

   ============================================================
   SPRÁVNÉ ROZLIŠENÍ
   ============================================================
   Od roku 2014 je stavba součástí pozemku, pokud není zapsaná
   jako samostatná nemovitost. Popis to rozlišuje textem
   „součástí je stavba":

   | k. ú.            | součástí pozemku | samostatná | prům. JC |
   |------------------|------------------|------------|----------|
   | Horní Počernice  |               57 |         29 |   50 813 |
   | Jablonec n. N.   |                9 |          4 |   59 614 |
   | Květnice         |               57 |          3 |   86 023 |
   | Štěrboholy       |               53 |          0 |   77 196 |
   | Košíře           |               47 |          0 |  101 588 |
   | Stodůlky         |               39 |          0 |  121 072 |

   Horní Počernice jsou jediné území s významným počtem
   samostatných staveb; všude jinde nula nebo jednotky. To
   odpovídá odděleném vlastnictví, které tam znalec zjistil
   při zpracování posudku.

   Příznak se proto staví na dvou podmínkách zároveň:

     1) stavba NENÍ součástí pozemku (je samostatnou věcí), A
     2) ve vkladu se prodávají parcely, ale ta pod stavbou
        mezi nimi není

   Teprve pak je nejisté, k čemu se cena vztahuje. Ostatní tři
   kombinace jsou běžné a jednotková cena u nich platí:

     stavba je součástí pozemku           → cena patří celku
     samostatná, parcela pod ní v prodeji → cena patří celku
     samostatná, žádná parcela ve vkladu  → cena patří stavbě

   Nerozhoduje se podle ceny ani podle druhu pozemku — to by byl
   kruhový argument.
   ============================================================ */

USE VALUO;
GO

/* ---------- 22a.1 POMOCNÝ POHLED S PŘÍZNAKEM --------------- */

CREATE OR ALTER VIEW dbo.v_Valuo_parcela_z_popisu
AS
SELECT  id,
        cislo_vkladu,
        nemovitost,
        vklad_klasifikace,
        je_stavebni,
        je_soucasti_pozemku,
        LTRIM(RTRIM(bez_zavorek)) AS parcela_s_uzemim
FROM (
    SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace,
           je_stavebni, je_soucasti_pozemku,
           CASE WHEN CHARINDEX(N' (', za_prefixem) > 0
                THEN LEFT(za_prefixem, CHARINDEX(N' (', za_prefixem) - 1)
                ELSE za_prefixem END AS bez_zavorek
    FROM (
        SELECT id, cislo_vkladu, nemovitost, vklad_klasifikace,
               CASE WHEN popis LIKE N'stavební č. %' THEN 1 ELSE 0 END AS je_stavebni,
               CASE WHEN popis LIKE N'%součástí je stavba%' THEN 1 ELSE 0 END
                                                                AS je_soucasti_pozemku,
               CASE WHEN popis LIKE N'stavební č. %' THEN SUBSTRING(popis, 13, 400)
                    WHEN popis LIKE N'č. %'          THEN SUBSTRING(popis,  4, 400)
               END AS za_prefixem
        FROM dbo.Valuo_data
    ) a
    WHERE za_prefixem IS NOT NULL
) b;
GO


/* ---------- 22a.2 ROZPAD JEVU ------------------------------
   Kontrola před změnou pohledů — ukáže, kolika vkladů se
   příznak dotkne.                                            */

SELECT  CASE WHEN b.je_soucasti_pozemku = 1       THEN N'1 stavba je součástí pozemku'
             WHEN pod.cislo_vkladu IS NOT NULL    THEN N'2 samostatná, parcela pod ní se prodává'
             WHEN pv.cislo_vkladu IS NULL         THEN N'3 samostatná, žádná parcela ve vkladu'
             ELSE                                      N'4 samostatná, prodávají se jiné parcely'
        END                                AS stav,
        COUNT(DISTINCT b.cislo_vkladu)     AS vkladu
FROM dbo.v_Valuo_parcela_z_popisu b
LEFT JOIN (SELECT DISTINCT cislo_vkladu
           FROM dbo.v_Valuo_parcela_z_popisu
           WHERE nemovitost = N'parcela') pv
       ON pv.cislo_vkladu = b.cislo_vkladu
LEFT JOIN dbo.v_Valuo_parcela_z_popisu pod
       ON pod.cislo_vkladu     = b.cislo_vkladu
      AND pod.nemovitost       = N'parcela'
      AND pod.parcela_s_uzemim = b.parcela_s_uzemim
WHERE b.nemovitost = N'budova'
  AND b.vklad_klasifikace = 'CELEK_BUDOVA'
GROUP BY CASE WHEN b.je_soucasti_pozemku = 1       THEN N'1 stavba je součástí pozemku'
              WHEN pod.cislo_vkladu IS NOT NULL    THEN N'2 samostatná, parcela pod ní se prodává'
              WHEN pv.cislo_vkladu IS NULL         THEN N'3 samostatná, žádná parcela ve vkladu'
              ELSE                                      N'4 samostatná, prodávají se jiné parcely'
         END
ORDER BY stav;
GO


/* ---------- 22a.3 ZÁKLADNÍ POHLED -------------------------- */

CREATE OR ALTER VIEW dbo.v_Valuo_vzorek
AS
WITH opakovani AS (
    SELECT  popis, plocha,
            COUNT(DISTINCT cislo_vkladu) AS prodeju
    FROM dbo.Valuo_data
    WHERE nemovitost = N'budova' AND plocha > 0
    GROUP BY popis, plocha
),
parcely_ve_vkladu AS (
    SELECT DISTINCT cislo_vkladu
    FROM dbo.v_Valuo_parcela_z_popisu
    WHERE nemovitost = N'parcela'
),
stavba_vs_pozemek AS (
    /* 0 jen při obou podmínkách zároveň: stavba je samostatná
       věc A parcela pod ní se neprodává, přesto se ve vkladu
       jiné parcely prodávají.                                */
    SELECT  b.cislo_vkladu,
            MIN(CASE WHEN b.je_soucasti_pozemku = 1    THEN 1
                     WHEN pod.cislo_vkladu IS NOT NULL THEN 1
                     WHEN pv.cislo_vkladu IS NULL      THEN 1
                     ELSE 0 END) AS cena_patri_stavbe
    FROM dbo.v_Valuo_parcela_z_popisu b
    LEFT JOIN parcely_ve_vkladu pv
           ON pv.cislo_vkladu = b.cislo_vkladu
    LEFT JOIN dbo.v_Valuo_parcela_z_popisu pod
           ON pod.cislo_vkladu     = b.cislo_vkladu
          AND pod.nemovitost       = N'parcela'
          AND pod.parcela_s_uzemim = b.parcela_s_uzemim
    WHERE b.nemovitost = N'budova'
    GROUP BY b.cislo_vkladu
),
vklad AS (
    SELECT  v.cislo_vkladu,
            MIN(v.id)                      AS id_prvni,
            MIN(v.datum_zplatneni)         AS datum_zplatneni,
            MIN(v.rok)                     AS rok,
            MIN(v.mesic)                   AS mesic,
            MIN(v.kod_ku)                  AS kod_ku,
            MAX(v.cena_Kc)                 AS cena,
            MAX(v.cenovy_udaj)             AS cena_v_mene,
            MIN(v.mena)                    AS mena,
            MIN(v.kurz_pouzity)            AS kurz_pouzity,
            MIN(v.kurz_datum)              AS kurz_datum,
            MIN(v.typ_prevodu)             AS typ_prevodu,
            MIN(v.vklad_klasifikace)       AS klasifikace,
            MIN(v.vklad_duvod)             AS duvod,
            MIN(v.vklad_nemovitosti)       AS nemovitosti,
            MIN(v.vklad_duplicit)          AS duplicit,
            MIN(v.vklad_plocha_parcel)     AS plocha_parcel,
            MIN(v.vklad_plocha_jednotky)   AS plocha_jednotky,
            MIN(v.vklad_plocha_budovy)     AS plocha_budovy,

            MAX(CASE WHEN v.popis LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS na_pozemku_stavba,

            /* stavba zapsaná jako samostatná nemovitost */
            MAX(CASE WHEN v.nemovitost = N'budova'
                      AND v.popis NOT LIKE N'%součástí je stavba%'
                     THEN 1 ELSE 0 END)    AS stavba_samostatna,

            MIN(CASE WHEN v.nemovitost = N'budova'
                     THEN v.typ_plochy END) AS typ_plochy_stavby,

            MAX(CASE WHEN v.nemovitost = N'budova'
                     THEN o.prodeju END)    AS prodeju_tehoz_objektu,

            MIN(CASE WHEN v.vklad_klasifikace = 'JC_JEDNOTKA'
                      AND v.nemovitost = N'jednotka' THEN v.typ
                     WHEN v.vklad_klasifikace = 'CELEK_BUDOVA'
                      AND v.nemovitost = N'budova'   THEN v.typ
                     WHEN v.vklad_klasifikace = 'JC_PARCELY'
                      AND v.nemovitost = N'parcela'  THEN v.typ
                END)                       AS druh,
            COUNT(DISTINCT v.typ)          AS ruznych_druhu
    FROM dbo.Valuo_data v
    LEFT JOIN opakovani o ON o.popis = v.popis AND o.plocha = v.plocha
                         AND v.nemovitost = N'budova'
    WHERE v.geo_zdroj   = 'KN_refPoint'
      AND v.cenovy_udaj > 0
    GROUP BY v.cislo_vkladu
)
SELECT  k.cislo_vkladu,
        k.datum_zplatneni,
        k.rok,
        k.mesic,

        k.kod_ku,
        c.ku_nazev                              AS kat_uzemi,
        c.obec_nazev                            AS obec,
        COALESCE(c.okres_nazev, c.kraj_nazev)   AS okres,
        c.kraj_nazev                            AS kraj,

        k.klasifikace,
        k.duvod,
        k.typ_prevodu,
        k.druh,
        k.ruznych_druhu,
        k.nemovitosti                           AS nemovitosti_ve_vkladu,
        k.duplicit                              AS duplicitnich_radku,
        k.na_pozemku_stavba,
        k.stavba_samostatna,
        k.typ_plochy_stavby,
        k.prodeju_tehoz_objektu,
        ISNULL(sp.cena_patri_stavbe, 1)         AS cena_patri_stavbe,

        k.plocha_parcel                         AS plocha_parcel_m2,
        k.plocha_jednotky                       AS plocha_jednotky_m2,
        k.plocha_budovy                         AS plocha_budovy_m2,

        CASE WHEN k.typ_plochy_stavby = N'Podlahová plocha'
             THEN k.plocha_budovy END           AS plocha_podlahova_m2,

        k.cena                                  AS cena_Kc,
        k.mena,
        k.cena_v_mene,
        k.kurz_pouzity,
        k.kurz_datum,

        CASE
            WHEN k.klasifikace = 'JC_PARCELY' AND k.na_pozemku_stavba = 1
                 THEN NULL
            WHEN k.klasifikace = 'JC_PARCELY'
                 THEN CAST(k.cena / NULLIF(k.plocha_parcel, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'JC_JEDNOTKA'
                 THEN CAST(k.cena / NULLIF(k.plocha_jednotky, 0) AS decimal(14,2))
            WHEN k.klasifikace = 'CELEK_BUDOVA'
             AND k.typ_plochy_stavby = N'Podlahová plocha'
             AND ISNULL(sp.cena_patri_stavbe, 1) = 1
                 THEN CAST(k.cena / NULLIF(k.plocha_budovy, 0) AS decimal(14,2))
            ELSE NULL
        END                                     AS jedn_cena_Kc_m2,

        p.geo_bod,
        p.LAT,
        p.LON
FROM vklad k
JOIN dbo.Valuo_data p            ON p.id     = k.id_prvni
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = k.kod_ku
LEFT JOIN stavba_vs_pozemek sp   ON sp.cislo_vkladu = k.cislo_vkladu;
GO


/* ---------- 22a.4 KONTROLA --------------------------------- */

SELECT cena_patri_stavbe, stavba_samostatna, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek WHERE klasifikace = 'CELEK_BUDOVA'
GROUP BY cena_patri_stavbe, stavba_samostatna
ORDER BY cena_patri_stavbe, stavba_samostatna;
GO

/* Kde se příznak vyskytuje */
SELECT TOP 12 kat_uzemi, druh, COUNT(*) AS vkladu,
       CAST(AVG(cena_Kc) AS decimal(14,0)) AS prum_cena
FROM dbo.v_Valuo_vzorek
WHERE klasifikace = 'CELEK_BUDOVA' AND cena_patri_stavbe = 0
GROUP BY kat_uzemi, druh ORDER BY COUNT(*) DESC;
GO

/* Medián rodinných domů — před krokem 22 bylo Horní Počernice
   31 254 Kč/m2 při 69 bodech, ostatní Praha 82 000 až 170 000 */
SELECT c.ku_nazev AS kat_uzemi, h.median AS median_Kc_m2, h.bodu
FROM dbo.v_cenove_hladiny h
JOIN dbo.CIS_katastralni_uzemi c ON c.ku_kod = h.kod_ku
WHERE h.klasifikace = 'CELEK_BUDOVA' AND h.klic = N'DRUH:rodinný dům'
  AND h.uroven = N'k.ú.' ORDER BY h.bodu DESC;
GO

/* Hladiny podle úrovně — po 21a bylo CELEK_BUDOVA 37/75/21 */
SELECT klasifikace, uroven, COUNT(*) AS kombinaci, SUM(bodu) AS bodu
FROM dbo.v_cenove_hladiny GROUP BY klasifikace, uroven
ORDER BY klasifikace, uroven;
GO

/* Vzorek */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO
