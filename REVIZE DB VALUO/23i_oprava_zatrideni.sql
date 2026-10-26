/* ============================================================
   VALUO — KROK 23i: OPRAVA ZATŘÍDĚNÍ

   Mění jen sloupce typ_jevu a poznamka v tabulce skupin.
   Do dat nezasahuje. Spusť celé najednou.

   ============================================================
   CO SE OPRAVUJE
   ============================================================
   1  Pět pozemkových skupin zatříděných jako TRH jsou ve
      skutečnosti stavební parcely vedené v katastru jako orná
      půda. Poznají se podle výměry:

      | k. ú.        |    JC | vkladů | výměry      |
      |--------------|-------|--------|-------------|
      | Králův Dvůr  | 9 400 |      5 | 650-912 m2  |
      | Králův Dvůr  | 8 800 |      5 | 799-810 m2  |
      | Tuklaty      | 7 998 |      7 | 801-822 m2  |
      | Tuklaty      | 7 598 |      8 | 801-805 m2  |
      | Nymburk      | 3 500 |     16 | 613-876 m2  |

      Výměry 613 až 912 m2 a ceny 2,1 až 8,6 milionu za parcelu
      odpovídají stavebním parcelám, ne orné půdě. Mediány orné
      půdy v těch územích jsou 3 500 až 4 763 Kč/m2, tedy pod
      těmito cenami.

   2  Čtyři skupiny jednotek zatříděné jako TRH jsou ceníkové
      prodeje za pevnou sazbu za metr.

   ------------------------------------------------------------
   JAK SE CENÍK POZNÁ OD NÁHODY
   ------------------------------------------------------------
   Shodná jednotková cena sama o sobě nic neznamená: je-li cena
   kulatá a výměra celočíselná, vyjde kulatá jednotková cena i u
   nezávislých prodejů. 200 000 / 20 = 10 000 stejně jako
   360 000 / 36.

   Rozhodne výměra s desetinnými místy. Vyjde-li i u ní cena na
   korunu jako výměra × sazba, nemohla vzniknout jinak než
   výpočtem:

      Poděbrady   49,40 m2 × 2 500 = 123 500 Kč
                  52,30 m2 × 2 500 = 130 750 Kč
                  51,20 m2 × 2 500 = 128 000 Kč

   | k. ú.      | druh      |      JC | desetinných | přesných |
   |------------|-----------|---------|-------------|----------|
   | Nové Město | byt       | 140 000 |           7 |        7 |
   | Košíře     | byt       | 125 000 |           4 |        4 |
   | Žižkov     | byt       | 120 750 |           4 |        4 |
   | Poděbrady  | jiný neb. |   2 500 |           4 |        4 |

   U všech čtyř sedí každá desetinná výměra na korunu.

   ------------------------------------------------------------
   CO ZŮSTÁVÁ JAKO TRH
   ------------------------------------------------------------
   | k. ú.      | druh      |      JC | domů | rozsah  |
   |------------|-----------|---------|------|---------|
   | Chodov     | byt       | 100 000 |    5 | 390 dní |
   | Nové Město | jiný neb. |  10 000 |    3 | 882 dní |
   | Modřany    | jiný neb. |   6 050 |    2 | 493 dní |

   Tyhle tři mají jen celočíselné výměry, takže se tím testem
   rozhodnout nedají. Chodov v pěti domech za rok a Nové Město
   ve třech za dva a půl roku na jednu akci nevypadají.

   Modřany jsou sporné: dvě sousední čísla popisná 2416 a 2417,
   tedy nejspíš jeden komplex, a sazba 6 050 Kč/m2 není kulatá,
   což u náhody překvapí. Příkaz na ně je v oddílu 23i.4
   zakomentovaný — rozhodni podle toho, co uvidíš v mapě.
   ============================================================ */

USE VALUO;
GO

/* ---------- 23i.1 STAV PŘED ------------------------------- */

SELECT klasifikace, kat_uzemi, druh, jedn_cena_Kc_m2, vkladu,
       CAST(plocha_min AS decimal(10,0)) AS pl_min,
       CAST(plocha_max AS decimal(10,0)) AS pl_max,
       typ_jevu
FROM dbo.Valuo_hromadne_prevody
WHERE typ_jevu = 'TRH'
ORDER BY klasifikace, jedn_cena_Kc_m2 DESC;
GO


/* ---------- 23i.2 STAVEBNÍ PARCELY -------------------------
   Všechny pozemkové skupiny v TRH; žádná jiná tam není, takže
   podmínka na klasifikaci stačí a nic dalšího nezasáhne.     */

UPDATE dbo.Valuo_hromadne_prevody
   SET typ_jevu = 'STAVEBNI_PARCELY',
       poznamka = N'Stavební parcely vedené v katastru jako orná půda. Výměry odpovídají parcelaci, ceny mnohonásobně nad mediánem orné půdy v území.'
 WHERE klasifikace = 'JC_PARCELY'
   AND typ_jevu = 'TRH';
GO

PRINT N'přepsáno na STAVEBNI_PARCELY: ' + CAST(@@ROWCOUNT AS varchar);
GO


/* ---------- 23i.3 CENÍKOVÉ PRODEJE -------------------------
   Vyjmenované po jedné celým klíčem, ať se nedotkne ničeho
   jiného.                                                     */

UPDATE dbo.Valuo_hromadne_prevody
   SET typ_jevu = 'CENIK_NOVOSTAVBA',
       poznamka = N'Ceníkový prodej za pevnou sazbu za metr. Cena vychází na korunu i u výměr s desetinnými místy.'
 WHERE klasifikace = 'JC_JEDNOTKA'
   AND (   (kat_uzemi = 'Nové Město' AND druh = 'byt'
            AND jedn_cena_Kc_m2 = 140000.00)
        OR (kat_uzemi = 'Košíře'     AND druh = 'byt'
            AND jedn_cena_Kc_m2 = 125000.00)
        OR (kat_uzemi = 'Žižkov'     AND druh = 'byt'
            AND jedn_cena_Kc_m2 = 120750.00));
GO

PRINT N'přepsáno na CENIK_NOVOSTAVBA (byty): ' + CAST(@@ROWCOUNT AS varchar);
GO

/* Poděbrady zvlášť — jde o příslušenství, ne o byty, a poznámka
   to má říkat                                                 */
UPDATE dbo.Valuo_hromadne_prevody
   SET typ_jevu = 'CENIK_NOVOSTAVBA',
       poznamka = N'Doprodej příslušenství (sklepy nebo stání) ve dvou domech č.p. 122 a 134 za sazbu 2 500 Kč/m2. Cena přesný násobek výměry, 2023-2024.'
 WHERE klasifikace = 'JC_JEDNOTKA' AND kat_uzemi = 'Poděbrady'
   AND druh = 'jiný nebytový prostor' AND jedn_cena_Kc_m2 = 2500.00;
GO

PRINT N'přepsáno na CENIK_NOVOSTAVBA (Poděbrady): ' + CAST(@@ROWCOUNT AS varchar);
GO


/* ---------- 23i.4 MODŘANY — ROZHODNI SÁM -------------------
   Dvě sousední čísla popisná 2416 a 2417, deset vkladů za 493
   dní, sazba 6 050 Kč/m2. Všechny výměry celočíselné, takže
   důkaz přesným násobkem chybí. Chceš-li je přehodit, odkomentuj:

   UPDATE dbo.Valuo_hromadne_prevody
      SET typ_jevu = 'CENIK_NOVOSTAVBA',
          poznamka = N'Doprodej příslušenství ve dvou sousedních domech č.p. 2416 a 2417 za sazbu 6 050 Kč/m2.'
    WHERE klasifikace = 'JC_JEDNOTKA' AND kat_uzemi = 'Modřany'
      AND druh = 'jiný nebytový prostor' AND jedn_cena_Kc_m2 = 6050.00;
   ------------------------------------------------------------ */


/* ---------- 23i.5 KONTROLA -------------------------------- */

/* Rozdělení po opravě */
SELECT typ_jevu, COUNT(*) AS skupin, SUM(vkladu) AS vkladu
FROM dbo.Valuo_hromadne_prevody
GROUP BY typ_jevu ORDER BY SUM(vkladu) DESC;
GO

/* Co zůstalo jako TRH — mají zbýt Chodov a Nové Město,
   případně Modřany                                           */
SELECT kat_uzemi, druh, jedn_cena_Kc_m2, vkladu, pomer
FROM dbo.Valuo_hromadne_prevody
WHERE typ_jevu = 'TRH' ORDER BY kat_uzemi;
GO

/* Stavební parcely pohromadě — tohle je teď tvůj vzorek
   realizovaných cen stavebních parcel                        */
SELECT kat_uzemi, jedn_cena_Kc_m2, vkladu,
       CAST(plocha_min AS decimal(10,0)) AS pl_min,
       CAST(plocha_max AS decimal(10,0)) AS pl_max,
       rok_min, rok_max
FROM dbo.Valuo_hromadne_prevody
WHERE typ_jevu = 'STAVEBNI_PARCELY'
ORDER BY jedn_cena_Kc_m2 DESC;
GO

/* Hladiny se mění jen tam, kde se něco vrátilo do mediánu nebo
   z něj odešlo. Vzorek po opravě:                            */
SELECT hodnoceni_ceny, COUNT(*) AS vkladu
FROM dbo.v_Valuo_vzorek_q
GROUP BY hodnoceni_ceny ORDER BY COUNT(*) DESC;
GO
