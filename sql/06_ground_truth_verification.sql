-- ============================================================
-- Query 06: Ground Truth Verification of Model Predictions
-- After running the Python model and getting risk scores,
-- use these queries to verify predictions against reality
-- ============================================================

-- Step 1: Verify a specific high-risk patient's trajectory
-- Replace subject_id values with IDs from flagged_patients_mimiciv.csv
SELECT
    a.subject_id,
    a.hadm_id,
    a.admittime,
    a.dischtime,
    a.hospital_expire_flag,
    CASE WHEN i.hadm_id IS NOT NULL
         THEN 'ICU' ELSE 'Ward' END         AS admission_type,
    ROUND(EXTRACT(EPOCH FROM
        (a.dischtime-a.admittime))/86400,1) AS los_days,

    -- Peak MELD labs
    (SELECT MAX(valuenum) FROM hosp.labevents l
     WHERE l.subject_id=a.subject_id
       AND l.hadm_id=a.hadm_id
       AND l.itemid=50885) AS peak_bili,
    (SELECT MAX(valuenum) FROM hosp.labevents l
     WHERE l.subject_id=a.subject_id
       AND l.hadm_id=a.hadm_id
       AND l.itemid=50912) AS peak_creat,
    (SELECT MAX(valuenum) FROM hosp.labevents l
     WHERE l.subject_id=a.subject_id
       AND l.hadm_id=a.hadm_id
       AND l.itemid=51237) AS peak_inr,

    -- Top 3 diagnoses
    (SELECT STRING_AGG(di.long_title, ' | ' ORDER BY d.seq_num)
     FROM (
         SELECT DISTINCT ON (d2.icd_code)
             d2.icd_code, d2.seq_num
         FROM hosp.diagnoses_icd d2
         WHERE d2.subject_id=a.subject_id
           AND d2.hadm_id=a.hadm_id
           AND d2.seq_num <= 3
         ORDER BY d2.icd_code, d2.seq_num
     ) d
     JOIN hosp.d_icd_diagnoses di
         ON d.icd_code=di.icd_code) AS top_diagnoses

FROM hosp.admissions a
LEFT JOIN (SELECT DISTINCT hadm_id FROM icu.icustays) i
    ON a.hadm_id=i.hadm_id
WHERE a.subject_id IN (
    -- Top flagged patients from model output
    11345335, 10916044, 10944305,
    10971616, 10670524, 10521848,
    11004856, 11019070, 11431240, 10382575
)
ORDER BY a.subject_id, a.admittime;

-- ============================================================
-- Step 2: Validate deterioration criteria for flagged patients
-- Shows exactly which criterion triggered for each patient
-- ============================================================
WITH flagged AS (
    -- Replace with actual flagged subject_ids from model output
    SELECT unnest(ARRAY[
        11345335, 10916044, 10944305, 10971616, 10670524,
        10521848, 11004856, 11019070, 11431240, 10382575
    ]) AS subject_id
),

admissions_ordered AS (
    SELECT
        a.subject_id, a.hadm_id, a.admittime, a.dischtime,
        a.hospital_expire_flag,
        ROW_NUMBER() OVER (
            PARTITION BY a.subject_id
            ORDER BY a.admittime
        ) AS adm_num
    FROM hosp.admissions a
    WHERE a.subject_id IN (SELECT subject_id FROM flagged)
),

-- MELD per admission
meld_per_adm AS (
    SELECT
        ao.subject_id, ao.hadm_id, ao.adm_num,
        ao.hospital_expire_flag,
        LEAST(40, GREATEST(6, ROUND((
            3.78*LN(GREATEST(1.0,LEAST(82.0,b.v)))+
            11.2*LN(GREATEST(1.0,LEAST(10.0,i.v)))+
            9.57*LN(GREATEST(1.0,LEAST(4.0,c.v)))+6.43+
            1.32*(137-GREATEST(125.0,LEAST(137.0,s.v)))-
            0.033*(3.78*LN(GREATEST(1.0,LEAST(82.0,b.v)))+
                   11.2*LN(GREATEST(1.0,LEAST(10.0,i.v)))+
                   9.57*LN(GREATEST(1.0,LEAST(4.0,c.v)))+6.43)*
                  (137-GREATEST(125.0,LEAST(137.0,s.v)))
        )::numeric,1))) AS meld_na
    FROM admissions_ordered ao
    JOIN (SELECT subject_id,hadm_id,MAX(valuenum) AS v
          FROM hosp.labevents WHERE itemid=50885 AND valuenum>0
          GROUP BY subject_id,hadm_id) b
        ON ao.subject_id=b.subject_id AND ao.hadm_id=b.hadm_id
    JOIN (SELECT subject_id,hadm_id,MAX(valuenum) AS v
          FROM hosp.labevents WHERE itemid=50912 AND valuenum>0
          GROUP BY subject_id,hadm_id) c
        ON ao.subject_id=c.subject_id AND ao.hadm_id=c.hadm_id
    JOIN (SELECT DISTINCT ON (subject_id,hadm_id)
              subject_id,hadm_id,valuenum AS v
          FROM hosp.labevents WHERE itemid=51237 AND valuenum>0
          ORDER BY subject_id,hadm_id,charttime DESC) i
        ON ao.subject_id=i.subject_id AND ao.hadm_id=i.hadm_id
    JOIN (SELECT DISTINCT ON (subject_id,hadm_id)
              subject_id,hadm_id,valuenum AS v
          FROM hosp.labevents WHERE itemid IN(50983,50824) AND valuenum>0
          ORDER BY subject_id,hadm_id,charttime DESC) s
        ON ao.subject_id=s.subject_id AND ao.hadm_id=s.hadm_id
),

-- Deterioration criteria check
deterioration_check AS (
    SELECT
        curr.subject_id,
        curr.adm_num     AS current_admission,
        curr.meld_na     AS current_meld,
        next_.meld_na    AS next_meld,
        ROUND((next_.meld_na - curr.meld_na)::numeric,1) AS meld_delta,
        next_.hospital_expire_flag AS died_next_admission,

        -- Option C criteria
        CASE WHEN (next_.meld_na - curr.meld_na) >= 5
             THEN 'YES' ELSE 'no' END AS criterion_meld_delta_5,
        CASE WHEN next_.meld_na >= 30
             THEN 'YES' ELSE 'no' END AS criterion_meld_30,
        CASE WHEN next_.hospital_expire_flag = 1
             THEN 'YES' ELSE 'no' END AS criterion_died,

        -- Decompensation at next admission
        (SELECT MAX(CASE WHEN icd_code IN ('K767','5724')
                         THEN 'YES' ELSE 'no' END)
         FROM hosp.diagnoses_icd
         WHERE subject_id=next_.subject_id
           AND hadm_id=(SELECT hadm_id FROM admissions_ordered
                        WHERE subject_id=next_.subject_id
                          AND adm_num=next_.adm_num)) AS hepatorenal_next,

        (SELECT MAX(CASE WHEN icd_code IN ('K720','K721','K729','5722')
                         THEN 'YES' ELSE 'no' END)
         FROM hosp.diagnoses_icd
         WHERE subject_id=next_.subject_id
           AND hadm_id=(SELECT hadm_id FROM admissions_ordered
                        WHERE subject_id=next_.subject_id
                          AND adm_num=next_.adm_num)) AS encephalopathy_next

    FROM meld_per_adm curr
    JOIN meld_per_adm next_
        ON curr.subject_id=next_.subject_id
        AND curr.adm_num=next_.adm_num-1
)

SELECT * FROM deterioration_check
ORDER BY subject_id, current_admission;
