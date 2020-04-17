WITH 
/*
    ================================================== VARIABLES ==================================================
    
    Set up the pseudo-variables we will use with the query, the
    start, end, and block size of capacity you have to buy for DDB
*/
    variables 
AS
(
    SELECT
        CAST(start_date as DATE) AS start_date,
        CAST(end_date as DATE) AS end_date,
        accountid,
        reserved_capacity_block_size
    FROM
        (
          VALUES
          ('2020-01-01', '2020-01-31', '252486826203', 100)
        )
        AS t1(start_date, end_date, accountid, reserved_capacity_block_size)
),

    usage_by_region
AS 
(
    SELECT 
        product_region AS region,
        product_usagetype AS usage_type,
        SUM(line_item_usage_amount) AS total_usage, -- The total usage in the region
        MAX(line_item_usage_start_date) AS latest, -- The most recent usage time
        MIN(start_date) AS start_date, -- The start date for the report, inclusive
        MAX(end_date) AS end_date, -- The end date for the report, non-inclusive  
        MAX(product_sku) AS sku, -- The unique sku for the charge
        ARRAY_AGG(DISTINCT line_item_resource_id) as "tables", -- The tables that contributed to the usage, i.e. unique resources
        MAP_AGG(line_item_usage_start_date, line_item_usage_amount) AS usage_per_hour, -- create a map that has the start date as the key and the usage for that hour as the value
        MAX(var.reserved_capacity_block_size) as reserved_capacity_block_size
    FROM 
        "billingdata"."2020-01-01", variables AS var
    WHERE 
        pricing_term = 'OnDemand'
        AND
            (product_servicecode = 'AmazonDynamoDB'
                AND 
             regexp_like(product_usagetype,'\bWriteCapacityUnit-Hrs|\bReadCapacityUnit-Hrs')
            ) -- DynamoDB read/write capacity units 
        AND
            line_item_usage_start_date >= var.start_date
        AND
            line_item_usage_start_date < var.end_date 
        AND 
            line_item_usage_account_id = var.accountid
     GROUP BY 
         product_region, product_usagetype
),

    agg_usage -- only need to do this statement because the previous uses group by and we need to map_concat the initial state and the actual hourly usage
AS 
(
    SELECT 
        region,
        usage_type,
        total_usage, -- The total usage in the region
        latest, -- The most recent usage time
        start_date, -- The start date for the report, inclusive
        end_date, -- The end date for the report, non-inclusive  
        sku, -- The unique sku for the charge
        "tables", -- The tables that contributed to the usage
        usage_per_hour,
        map_concat( -- have to do map_concat in this query because the above query uses GROUP BY and this isn't an aggregate function
          MAP(           -- Create a Map of all of the hours in the period with an initial zero as the usage amount
              SEQUENCE(start_date, end_date, INTERVAL '1' HOUR), -- Creates the keys, which are the hours in the evaluation period
              transform(
                  SEQUENCE(start_date, end_date, INTERVAL '1' HOUR), 
                  x -> 0
              ) -- Creates the values, the same number of 0's as hours
          ),
          usage_per_hour -- concat the map of hours and zero values with the actual usage per hour, this will update any common keys with the actual usage
        ) AS usage_per_hour_for_timespan,
        reserved_capacity_block_size -- carry this over to use in the last query to determine blocks of 100 to buy
    FROM 
        usage_by_region
)

SELECT 
    ddb.service as Service,
    ddb.platform as Platform,
    ddb.region as Location,   
    ddb.ondemandhourlycost * reserved_capacity_block_size AS OnDemand,
    ddb.upfrontfee * reserved_capacity_block_size as UpfrontFee,
    ddb.leaseterm as LeaseTerm,
    ddb.purchaseoption as PurchaseOption,
    ddb.offeringclass as OfferingClass,
    ddb.adjustedpriceperunit * reserved_capacity_block_size as AdjustedPricePerUnit,
    ddb.reservedinstancecost * reserved_capacity_block_size as AmortizedRICost,
    ddb.ondemandcostforterm * reserved_capacity_block_size as OnDemandCostForTerm,
    ddb.costsavings * reserved_capacity_block_size as TotalCostSavingsForTerm,
    ddb.percentsavings as PercentSavings,
    ddb.breakevenpercentage as BreakevenPercentage,
    agg_usage.total_usage as TotalUsage,
    floor(
        COALESCE(
            reduce(
                map_values(agg_usage.usage_per_hour_for_timespan), -- Take the values of usage per hour, input data
                CAST(
                    ROW(
                        MAP(        -- Create a map of the total usages per hour, and the number of times they occur in the period, defaulting to 0
                            array_distinct(
                                map_values(agg_usage.usage_per_hour_for_timespan)
                            ),
                            transform(
                                array_distinct(
                                    map_values(agg_usage.usage_per_hour_for_timespan)
                                ),
                                x -> 0
                            )
                        )
                    ) AS ROW(map MAP(INTEGER, INTEGER))
                ),                                     -- this defines the initial state, so { 5: 0, 6: 0, 1: 0, 20: 0} the capacity used distinct values and 0 occurences
                (initial_state, hourly_usage) -> CAST( -- given the initial state and array of hourly usages, evaluate each hourly usage value
                    ROW(
                        transform_values(initial_state.map, (key, value) -> 
                            IF (hourly_usage <= key, value + 1, value)    -- Update all values if this usage quantity is less than or equal
                                                                        -- So if 6 were running, we also count that towards 5, 4, 3, 2, 1
                        )                                                            
                    ) AS ROW (map MAP(INTEGER, INTEGER))
                ), 
                updated_state -> array_max( 
                    map_keys(
                        map_filter(            -- Only take usage quantities that are greater than the breakeven
                            updated_state.map,
                            (key, total_capacity_used) -> total_capacity_used >= breakevenpercentage * cardinality(usage_per_hour_for_timespan) -- cardinality(usage_per_hour_for_timespan) represents the number of hours in our evaluation timespan
                        )
                    )
                )
            ), 
            0
        ) / reserved_capacity_block_size
    ) AS ReservedCapacityUnitsOf100,
    (agg_usage.total_usage / cardinality(usage_per_hour_for_timespan)) AS AverageUsagePerHour,
    agg_usage.tables as ResourceIds,
    agg_usage.usage_per_hour_for_timespan as UsagePerHour
    
FROM 
  agg_usage
LEFT OUTER JOIN
   "pricelist_database".dynamodb_formatted AS ddb
ON
  agg_usage.sku = ddb.sku
