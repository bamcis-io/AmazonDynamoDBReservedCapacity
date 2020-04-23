INSERT INTO "pricelist_database".dynamodb_formatted 

WITH
  region_map
AS(
    SELECT
		MAP_AGG(abbr, regioncode) AS map
    FROM
        (
          VALUES
          ( '', 'us-east-1'),
          ( 'USE1', 'us-east-1'),
          ( 'USE2', 'us-east-2' ),
          ( 'USW1', 'us-west-1' ),
          ( 'USW2', 'us-west-2' ),
          ( 'UGW1', 'us-gov-west-1' ),
          ( 'UGE1', 'us-gov-east-1' ),
          ( 'CAN1', 'ca-central-1' ),
          ( 'AFS1', 'af-south-1' ),
          ( 'APN1', 'ap-northeast-1' ),
          ( 'APN2', 'ap-northeast-2' ),
          ( 'APN3', 'ap-northeast-3' ),
          ( 'APS1', 'ap-southeast-1' ),
          ( 'APS2', 'ap-southeast-2' ),
          ( 'APS3', 'ap-south-1' ),
          ( 'APE1', 'ap-east-1' ),
          ( 'SAE1', 'sa-east-1' ),
          ( 'EU',   'eu-west-1' ),
          ( 'EUC1', 'eu-central-1' ),
          ( 'EUW2', 'eu-west-2' ),
          ( 'EUW3', 'eu-west-3' ),
          ( 'EUN1', 'eu-north-1' ),
          ( 'MES1', 'me-south-1' ),
          ( 'CNN1', 'cn-north-1' ),
          ( 'CNN2', 'cn-northwest-1')
        )
        AS t1(abbr, regioncode)
),

  reserved_capacity
AS(
  SELECT 
      reserved.sku,
      MAX(reserved.offertermcode) AS offertermcode,
      MAX(reserved.ratecode) AS ratecode,
      MAX(reserved."group") AS platform,
      CAST(MAX(DISTINCT ondemand.priceperunit) AS DOUBLE) AS ondemandhourlycost,
      MAX(reserved.offeringclass) AS offeringclass,
      reserved.usagetype,
      reserved.servicename,
      reserved.location AS region,
      CAST(substr(reserved.leasecontractlength, 1, 1) AS INTEGER) AS leasecontractlength,
      reserved.purchaseoption,
      CAST(array_max(map_values(map_filter(MAP_AGG(reserved.pricedescription, reserved.priceperunit), (key, value) -> key = 'Upfront Fee'))) AS DOUBLE) AS upfrontfee,
      CAST(array_max(map_values(map_filter(MAP_AGG(reserved.pricedescription, reserved.priceperunit), (key, value) -> key != 'Upfront Fee'))) AS DOUBLE) AS recurring
  FROM
      "pricelist-database".dynamodb AS reserved
  INNER JOIN 
      "pricelist-database".dynamodb AS ondemand
  ON 
      reserved.sku = ondemand.sku
        AND 
      ondemand.termtype = 'OnDemand'
        AND
      reserved.termtype = 'Reserved'
        AND
      NOT regexp_like(ondemand.pricedescription, '\(free tier\)')
        AND
      ondemand.endingrange = 'Inf'
  GROUP BY
    reserved.sku,
    reserved.usagetype,
    reserved.leasecontractlength,
    reserved.purchaseoption,
    reserved.location,
    reserved.servicename
),

    interim
AS(

SELECT 
    sku, 
    offertermcode,
    ratecode,
    platform, 
    usagetype, 
    region_map.map[COALESCE( regexp_extract(usagetype, '^([a-zA-Z]{2,3}[0-9]*)(-.*)$', 1), '')] AS region, 
    servicename AS service,
    recurring AS adjustedpriceperunit, 
    ondemandhourlycost, 
    upfrontfee, 
    leasecontractlength as leaseterm,
    purchaseoption,
    offeringclass,
    concat(CAST(leasecontractlength AS varchar), '::', replace(upper(purchaseoption), ' ', ''), '::', upper(offeringclass)) AS key,    
    ((leasecontractlength * 365 * 24 * recurring) + upfrontfee) AS reservedinstancecost,
    (leasecontractlength * 365 * 24 * ondemandhourlycost) AS ondemandcostforterm,
    ((upfrontfee + (365 * leasecontractlength * 24 * recurring)) / (365 * leasecontractlength * 24 * ondemandhourlycost)) AS breakevenpercentage
FROM 
    reserved_capacity, 
    region_map
)


SELECT 
    sku, 
    offertermcode,
    ratecode,
    platform, 
    usagetype, 
    region, 
    service,
    adjustedpriceperunit, 
    ondemandhourlycost, 
    breakevenpercentage,
    upfrontfee, 
    leaseterm,
    purchaseoption,
    offeringclass,
    key,    
    reservedinstancecost,
    ondemandcostforterm,
    (ondemandcostforterm - reservedinstancecost) AS costsavings,
    ((ondemandcostforterm - reservedinstancecost) / ondemandcostforterm) * 100 AS percentsavings
FROM interim
