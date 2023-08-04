/*
 * Copyright (c) Business Thinking Ltd. 2019-2023
 * This software includes code developed by the AutomateDV (f.k.a dbtvault) Team at Business Thinking Ltd. Trading as Datavault
 */

{%- macro sat(src_pk, src_hashdiff, src_payload, src_extra_columns, src_eff, src_ldts, src_source, source_model) -%}

    {{- automate_dv.check_required_parameters(src_pk=src_pk, src_hashdiff=src_hashdiff, src_payload=src_payload,
                                           src_ldts=src_ldts, src_source=src_source,
                                           source_model=source_model) -}}

    {%- set src_payload = automate_dv.process_payload_column_excludes(
                              src_pk=src_pk, src_hashdiff=src_hashdiff,
                              src_payload=src_payload, src_extra_columns=src_extra_columns, src_eff=src_eff,
                              src_ldts=src_ldts, src_source=src_source, source_model=source_model) -%}

    {{ automate_dv.prepend_generated_by() }}

    {{ adapter.dispatch('sat', 'automate_dv')(src_pk=src_pk, src_hashdiff=src_hashdiff,
                                           src_payload=src_payload, src_extra_columns=src_extra_columns,
                                           src_eff=src_eff, src_ldts=src_ldts,
                                           src_source=src_source, source_model=source_model) -}}

{%- endmacro -%}

{%- macro default__sat(src_pk, src_hashdiff, src_payload, src_extra_columns, src_eff, src_ldts, src_source, source_model) -%}

{%- set source_cols = automate_dv.expand_column_list(columns=[src_pk, src_hashdiff, src_payload, src_extra_columns, src_eff, src_ldts, src_source]) -%}
{%- set window_cols = automate_dv.expand_column_list(columns=[src_pk, src_hashdiff, src_ldts]) -%}
{%- set pk_cols = automate_dv.expand_column_list(columns=[src_pk]) -%}
{%- set enable_ghost_record = var('enable_ghost_records', false) %}

WITH source_data AS (
    SELECT {{ automate_dv.prefix(source_cols, 'a', alias_target='source') }}
    FROM {{ ref(source_model) }} AS a
    WHERE {{ automate_dv.multikey(src_pk, prefix='a', condition='IS NOT NULL') }}
),

{%- if automate_dv.is_any_incremental() %}

latest_records AS (
    SELECT {{ automate_dv.prefix(source_cols, 'current_records', alias_target='target') }},
        RANK() OVER (
           PARTITION BY {{ automate_dv.prefix([src_pk], 'current_records') }}
           ORDER BY {{ automate_dv.prefix([src_ldts], 'current_records') }} DESC
        ) AS rank_num
    FROM {{ this }} AS current_records
        JOIN (
            SELECT DISTINCT {{ automate_dv.prefix([src_pk], 'source_data') }}
            FROM source_data
        ) AS source_records
            ON {{ automate_dv.multikey(src_pk, prefix=['source_records','current_records'], condition='=') }}
    QUALIFY rank_num = 1
),

{%- endif %}

first_record_in_set AS (
    SELECT
    {{ automate_dv.prefix(source_cols, 'sd', alias_target='source') }},
    RANK() OVER (
            PARTITION BY {{ automate_dv.prefix([src_pk], 'sd', alias_target='source') }}
            ORDER BY {{ automate_dv.prefix([src_ldts], 'sd', alias_target='source') }} ASC
        ) as asc_rank
    FROM source_data as sd
    QUALIFY asc_rank = 1
),

unique_source_records AS (
    SELECT DISTINCT
        {{ automate_dv.prefix(source_cols, 'sd', alias_target='source') }}
    FROM source_data as sd
    QUALIFY {{ automate_dv.prefix([src_hashdiff], 'sd', alias_target='source') }} != LAG({{ automate_dv.prefix([src_hashdiff], 'sd', alias_target='source') }}) OVER (
        PARTITION BY {{ automate_dv.prefix([src_pk], 'sd', alias_target='source') }}
        ORDER BY {{ automate_dv.prefix([src_ldts], 'sd', alias_target='source') }} ASC)
),


{%- if enable_ghost_record %}

ghost AS (
    {{ automate_dv.create_ghost_record(src_pk=src_pk, src_hashdiff=src_hashdiff,
                                    src_payload=src_payload, src_extra_columns=src_extra_columns,
                                    src_eff=src_eff, src_ldts=src_ldts,
                                    src_source=src_source, source_model=source_model) }}
),

{%- endif %}

records_to_insert AS (
    {%- if enable_ghost_record %}
    SELECT
        {{ automate_dv.alias_all(source_cols, 'g') }}
        FROM ghost AS g
        {%- if automate_dv.is_any_incremental() %}
        WHERE NOT EXISTS ( SELECT 1 FROM {{ this }} AS h WHERE {{ automate_dv.prefix([src_hashdiff], 'h', alias_target='target') }} = {{ automate_dv.prefix([src_hashdiff], 'g') }} )
        {%- endif %}
    UNION {%- if target.type == 'bigquery' %} DISTINCT {%- endif %}
    {%- endif %}
    SELECT {{ automate_dv.alias_all(source_cols, 'frin') }}
    FROM first_record_in_set AS frin
    {%- if automate_dv.is_any_incremental() %}
    LEFT JOIN LATEST_RECORDS lr
        ON {{ automate_dv.multikey(src_pk, prefix=['lr','frin'], condition='=') }}
        AND {{ automate_dv.prefix([src_hashdiff], 'lr', alias_target='target') }} = {{ automate_dv.prefix([src_hashdiff], 'frin') }}
        WHERE {{ automate_dv.prefix([src_hashdiff], 'lr', alias_target='target') }} IS NULL
    {%- endif %}
    UNION {%- if target.type == 'bigquery' %} DISTINCT {%- endif %}
    SELECT {{ automate_dv.prefix(source_cols, 'usr', alias_target='source') }}
    FROM unique_source_records as usr
)

SELECT * FROM records_to_insert
{%- endmacro -%}
