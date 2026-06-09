-- ============================================================
-- Query 02: MELD-Na Computation Per Admission
-- Uses: peak bilirubin, peak creatinine, last INR, last sodium
-- Rationale:
--   Peak bili/creat: captures maximum organ dysfunction
--   Last INR/sodium: reflects treatment-adjusted status
-- ============================================================

WITH liver_patients AS (
    SELECT DISTINCT subject_id FROM hosp.diagnoses_icd
    WHERE (icd_version=10 AND icd_code IN (
        'K700','K701','K702','K703','K704','K709',
        'K720','K721','K729','K740','K741','K742',
        'K743','K744','K745','K746','K766','K767',
        'K760','B182','I850','I859','C220','C221'
    ))
    OR (icd_version=9 AND icd_code IN (
        '5710','5711','5712','5715','5722','5724','45620',
        '5720','5723','07054','1550','5716','5718'
    ))
),

-- PEAK bilirubin within each admission
peak_bili AS (
    SELECT l.subject_id, l.hadm_id,
           MAX(l.valuenum) AS peak_bilirubin
    FROM hosp.labevents l
    JOIN hosp.admissions a
        ON l.subject_id=a.subject_id AND l.hadm_id=a.hadm_id
    WHERE l.itemid=50885 AND l.valuenum>0
      AND l.charttime BETWEEN a.admittime AND a.dischtime
      AND l.subject_id IN (SELECT subject_id FROM liver_patients)
    GROUP BY l.subject_id, l.hadm_id
),

-- PEAK creatinine within each admission
peak_creat AS (
    SELECT l.subject_id, l.hadm_id,
           MAX(l.valuenum) AS peak_creatinine
    FROM hosp.labevents l
    JOIN hosp.admissions a
        ON l.subject_id=a.subject_id AND l.hadm_id=a.hadm_id
    WHERE l.itemid=50912 AND l.valuenum>0
      AND l.charttime BETWEEN a.admittime AND a.dischtime
      AND l.subject_id IN (SELECT subject_id FROM liver_patients)
    GROUP BY l.subject_id, l.hadm_id
),

-- LAST INR within each admission
last_inr AS (
    SELECT DISTINCT ON (l.subject_id, l.hadm_id)
        l.subject_id, l.hadm_id, l.valuenum AS last_inr
    FROM hosp.labevents l
    JOIN hosp.admissions a
        ON l.subject_id=a.subject_id AND l.hadm_id=a.hadm_id
    WHERE l.itemid=51237 AND l.valuenum>0
      AND l.charttime BETWEEN a.admittime AND a.dischtime
      AND l.subject_id IN (SELECT subject_id FROM liver_patients)
    ORDER BY l.subject_id, l.hadm_id, l.charttime DESC
),

-- LAST sodium within each admission (serum preferred)
last_sodium AS (
    SELECT DISTINCT ON (l.subject_id, l.hadm_id)
        l.subject_id, l.hadm_id, l.valuenum AS last_sodium
    FROM hosp.labevents l
    JOIN hosp.admissions a
        ON l.subject_id=a.subject_id AND l.hadm_id=a.hadm_id
    WHERE l.itemid IN (50983, 50824) AND l.valuenum>0
      AND l.charttime BETWEEN a.admittime AND a.dischtime
      AND l.subject_id IN (SELECT subject_id FROM liver_patients)
    ORDER BY l.subject_id, l.hadm_id, l.charttime DESC
),

-- Apply UNOS constraints and compute MELD
meld_scored AS (
    SELECT
        a.subject_id, a.hadm_id,
        a.admittime, a.dischtime,
        a.hospital_expire_flag,
        pb.peak_bilirubin, pc.peak_creatinine,
        li.last_inr, ls.last_sodium,
        -- Constrained values
        GREATEST(1.0, LEAST(82.0,  pb.peak_bilirubin)) AS bili_c,
        GREATEST(1.0, LEAST(4.0,   pc.peak_creatinine)) AS creat_c,
        GREATEST(1.0, LEAST(10.0,  li.last_inr))        AS inr_c,
        GREATEST(125.0,LEAST(137.0,ls.last_sodium))     AS sodium_c
    FROM hosp.admissions a
    LEFT JOIN peak_bili  pb ON a.subject_id=pb.subject_id AND a.hadm_id=pb.hadm_id
    LEFT JOIN peak_creat pc ON a.subject_id=pc.subject_id AND a.hadm_id=pc.hadm_id
    LEFT JOIN last_inr   li ON a.subject_id=li.subject_id AND a.hadm_id=li.hadm_id
    LEFT JOIN last_sodium ls ON a.subject_id=ls.subject_id AND a.hadm_id=ls.hadm_id
    WHERE a.subject_id IN (SELECT subject_id FROM liver_patients)
      AND pb.peak_bilirubin IS NOT NULL
      AND pc.peak_creatinine IS NOT NULL
      AND li.last_inr IS NOT NULL
)

-- Final MELD-Na scores with severity bands
SELECT
    ms.subject_id,
    ms.hadm_id,
    ms.admittime,
    ms.hospital_expire_flag,
    ROUND(ms.peak_bilirubin::numeric, 2)  AS peak_bili,
    ROUND(ms.peak_creatinine::numeric, 2) AS peak_creat,
    ROUND(ms.last_inr::numeric, 2)        AS last_inr,
    ROUND(ms.last_sodium::numeric, 1)     AS last_sodium,

    -- MELD score
    LEAST(40, GREATEST(6, ROUND((
        3.78  * LN(ms.bili_c)  +
        11.2  * LN(ms.inr_c)   +
        9.57  * LN(ms.creat_c) +
        6.43
    )::numeric, 1)))                      AS meld,

    -- MELD-Na score
    LEAST(40, GREATEST(6, ROUND((
        3.78  * LN(ms.bili_c) +
        11.2  * LN(ms.inr_c)  +
        9.57  * LN(ms.creat_c) + 6.43 +
        1.32  * (137 - ms.sodium_c) -
        0.033 * (3.78*LN(ms.bili_c)+11.2*LN(ms.inr_c)+
                 9.57*LN(ms.creat_c)+6.43)
              * (137 - ms.sodium_c)
    )::numeric, 1)))                      AS meld_na,

    -- Severity band
    CASE
        WHEN LEAST(40, GREATEST(6, ROUND((
                3.78*LN(ms.bili_c)+11.2*LN(ms.inr_c)+
                9.57*LN(ms.creat_c)+6.43+
                1.32*(137-ms.sodium_c)-
                0.033*(3.78*LN(ms.bili_c)+11.2*LN(ms.inr_c)+
                       9.57*LN(ms.creat_c)+6.43)*(137-ms.sodium_c)
             )::numeric,1))) <= 9  THEN 'Low (6-9)'
        WHEN LEAST(40, GREATEST(6, ROUND((
                3.78*LN(ms.bili_c)+11.2*LN(ms.inr_c)+
                9.57*LN(ms.creat_c)+6.43+
                1.32*(137-ms.sodium_c)-
                0.033*(3.78*LN(ms.bili_c)+11.2*LN(ms.inr_c)+
                       9.57*LN(ms.creat_c)+6.43)*(137-ms.sodium_c)
             )::numeric,1))) <= 19 THEN 'Moderate (10-19)'
        WHEN LEAST(40, GREATEST(6, ROUND((
                3.78*LN(ms.bili_c)+11.2*LN(ms.inr_c)+
                9.57*LN(ms.creat_c)+6.43+
                1.32*(137-ms.sodium_c)-
                0.033*(3.78*LN(ms.bili_c)+11.2*LN(ms.inr_c)+
                       9.57*LN(ms.creat_c)+6.43)*(137-ms.sodium_c)
             )::numeric,1))) <= 29 THEN 'High (20-29)'
        ELSE 'Urgent (30+)'
    END                                   AS meld_severity

FROM meld_scored ms
ORDER BY ms.subject_id, ms.admittime;
