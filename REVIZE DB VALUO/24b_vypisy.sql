/* ============================================================
   VALUO — PŘEHLED SPOČÍTANÝCH PRAHŮ

   Jen výpisy, nic nemění a nic nepočítá. Prahy už v tabulce
   Valuo_prahy jsou, tohle je jen čte.

   První dotaz je hlavní — jedna tabulka, kde každý řádek nese
   kategorii i jednotku, takže se dá řadit a filtrovat přímo
   v mřížce. Ostatní jsou výřezy.
   ============================================================ */

USE VALUO;
GO

/* ============================================================
   1) VŠECHNY PRAHY V JEDNÉ TABULCE
   ============================================================
   Co který sloupec znamená:

   kategorie   co se oceňuje
   jednotka    v čem je medián a prahy — Kč/m2 nebo Kč za vklad
   uroven      z jaké územní úrovně se počítalo
   uzemi       katastrální území, okres nebo kraj
   vzorku      KOLIK VKLADŮ ZA TÍM STOJÍ — podle toho se pozná,
               čemu věřit; třicet vkladů je něco jiného než dva
               tisíce
   median      prostřední hodnota
   zdola       pod tím je cena podezřelá
   shora       nad tím je cena podezřelá
   rozptyl     sigma z logaritmů; čím vyšší, tím širší pásmo
   ============================================================ */

SELECT
    kategorie = CASE
        WHEN p.klic LIKE N'FVU:%' THEN
             N'pozemek — ' + REPLACE(LEFT(REPLACE(p.klic, N'FVU:', N''),
                 CHARINDEX(N'|', REPLACE(p.klic, N'FVU:', N'')) - 1), N'_', N' ')
             + N', ' + SUBSTRING(p.klic, CHARINDEX(N'|', p.klic) + 1, 20) + N' m²'
        WHEN p.klasifikace = 'JC_JEDNOTKA' THEN
             N'jednotka — ' + REPLACE(p.klic, N'DRUH:', N'')
        WHEN p.klasifikace = 'CELEK_BUDOVA' THEN
             N'budova — '   + REPLACE(p.klic, N'DRUH:', N'')
        WHEN p.klasifikace = 'JC_PARCELY' THEN
             N'pozemek — '  + REPLACE(p.klic, N'DRUH:', N'')
        ELSE N'nezařazeno — ' + REPLACE(p.klic, N'DRUH:', N'')
    END,
    jednotka = CASE p.metrika WHEN 'JC' THEN N'Kč/m²'
                              ELSE N'Kč za vklad' END,
    p.uroven,
    uzemi   = p.uzemi,
    vzorku  = p.n,
    median  = CAST(p.median     AS decimal(14,0)),
    zdola   = CAST(p.prah_dolni AS decimal(14,0)),
    shora   = CAST(p.prah_horni AS decimal(14,0)),
    rozptyl = p.sigma
FROM dbo.Valuo_prahy p
ORDER BY kategorie, p.uroven, p.n DESC;
GO


/* ============================================================
   2) BYTY — kontrolní vzorek, hodnoty musí dávat smysl znalci
   ============================================================ */

SELECT  co = N'BYT, Kč/m² podlahové plochy',
        kat_uzemi = uzemi,
        vzorku = n,
        median = CAST(median AS decimal(12,0)),
        zdola  = CAST(prah_dolni AS decimal(12,0)),
        shora  = CAST(prah_horni AS decimal(12,0))
FROM dbo.Valuo_prahy
WHERE klic = N'DRUH:byt' AND uroven = N'k.ú.'
ORDER BY median DESC;
GO


/* ============================================================
   3) POZEMKY V PRAZE — skupina funkčního využití × výměra
   ============================================================
   Řádek "OBYTNE, 600-1500 m²" jsou stavební parcely pro rodinný
   dům ve funkčním využití pro bydlení. Řádek "OBYTNE, nad1500"
   jsou tytéž plochy, ale velké pozemky — tam leží podíly.
   ============================================================ */

SELECT  co = N'POZEMEK PRAHA, Kč/m²',
        skupina = LEFT(REPLACE(klic, N'FVU:', N''),
                       CHARINDEX(N'|', REPLACE(klic, N'FVU:', N'')) - 1),
        vymera  = SUBSTRING(klic, CHARINDEX(N'|', klic) + 1, 20),
        vzorku  = n,
        median  = CAST(median AS decimal(12,0)),
        zdola   = CAST(prah_dolni AS decimal(12,0)),
        shora   = CAST(prah_horni AS decimal(12,0))
FROM dbo.Valuo_prahy
WHERE klic LIKE N'FVU:%'
ORDER BY skupina, vymera;
GO


/* ============================================================
   4) GARÁŽE — cena za garáž, ne za metr
   ============================================================ */

SELECT  co = N'GARÁŽ, Kč za garáž',
        uroven, uzemi,
        vzorku = n,
        median = CAST(median AS decimal(12,0)),
        zdola  = CAST(prah_dolni AS decimal(12,0)),
        shora  = CAST(prah_horni AS decimal(12,0))
FROM dbo.Valuo_prahy
WHERE klic = N'DRUH:garáž'
ORDER BY uroven, n DESC;
GO


/* ============================================================
   5) OSTATNÍ JEDNOTKY A BUDOVY
   ============================================================ */

SELECT  co = CASE klasifikace WHEN 'JC_JEDNOTKA' THEN N'JEDNOTKA'
                              ELSE N'BUDOVA' END
             + N', ' + CASE metrika WHEN 'JC' THEN N'Kč/m²'
                                    ELSE N'Kč za vklad' END,
        druh   = REPLACE(klic, N'DRUH:', N''),
        uroven, uzemi,
        vzorku = n,
        median = CAST(median AS decimal(14,0)),
        zdola  = CAST(prah_dolni AS decimal(14,0)),
        shora  = CAST(prah_horni AS decimal(14,0))
FROM dbo.Valuo_prahy
WHERE klasifikace IN ('JC_JEDNOTKA', 'CELEK_BUDOVA')
  AND klic NOT IN (N'DRUH:byt', N'DRUH:garáž')
ORDER BY klasifikace, druh, uroven, n DESC;
GO


/* ============================================================
   6) KDE PRÁH CHYBÍ
   ============================================================
   Kombinace, kterým nezbylo dost vkladů ani na úrovni kraje.
   Tyhle vklady zůstanou bez kontroly, dokud se nesníží
   CIS_prahy_ceny.min_bodu_prah nebo nepřibudou data.
   ============================================================ */

SELECT  kategorie = CASE q.klasifikace
            WHEN 'JC_JEDNOTKA'  THEN N'jednotka'
            WHEN 'JC_PARCELY'   THEN N'pozemek'
            WHEN 'CELEK_BUDOVA' THEN N'budova'
            ELSE N'nezařazeno' END,
        druh = ISNULL(q.druh, N'?'),
        vkladu = COUNT(*)
FROM dbo.v_Valuo_vzorek_q q
WHERE q.hromadny_prevod = 0 AND q.typ_prevodu = 'KUPNI_SMLOUVA'
  AND q.rok >= YEAR(GETDATE()) - 5
  AND NOT EXISTS (
        SELECT 1 FROM dbo.Valuo_prahy p
        WHERE p.klasifikace = q.klasifikace
          AND p.klic = N'DRUH:' + ISNULL(q.druh, '?'))
  AND NOT EXISTS (
        SELECT 1 FROM dbo.Valuo_prahy p WHERE p.klic LIKE N'FVU:%'
          AND q.fvu_kod IS NOT NULL)
GROUP BY q.klasifikace, q.druh
HAVING COUNT(*) >= 20
ORDER BY COUNT(*) DESC;
GO
