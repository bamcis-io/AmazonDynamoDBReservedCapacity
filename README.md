# Amazon DynamoDB Reserved Capacity
This project allows you to self-service calculating what an optimal amount of reserved capacity is for your accounts.

## Algorithm
The calculation follows this basic algorithm. 

1) Establish a sequence of hours from some start time to some end time as the keys in a map whose values are initially 0.
2) Look at the AWS Cost and Usage report and update the map's values to the actual usage for provisioned Write Capacity Units and Read Capacity Units in each region.
3) Convert that map to a new map whose keys are the amounts of usage seen during the period and whose values are the number of times that usage occured during the period. For example, given a 6 hour period whose usage was 500, 600, 900, 900, 300, 900, the resulting map here would be {300: 6, 500: 5, 600: 4, 900: 3}. 300 has a value of 6, because during 6 hours in the evaluation period, there was usage of at least 300. 500 has as value of 5 because 5 out of 6 hours during the evaluation period has usage of at least 500 (the only one that did not was the one with only 300).
4) Utilize a formatted version of the Price List API data for DynamoDB that includes all reserved capacity offerings, as well as the current on demand cost and breakeven percentage.
   i) The breakeven percentage is important. Due to the upfront fees and committed spend over some term, at some level of usage over the evaluation period, it can be cheaper to run on demand vs buying reserved capacity. We need to know what the threshold is when buying reserved capacity costs less than running on demand.
5) Given the map of usage values to occurences, find the largest number of occurences that is greater than the number of hours in the evaluation times the breakeven percentage. This maximum value's key is the actual amount of usage that you should buy reserved capacity for since it represents the largest amount of capacity you could buy without crossing the break even point.
6) DynamoDB reserved capacity is purchased on blocks of 100, so while the evaluation was based on individual RCUs and WCUs, the actual recommendation will be in chunks of 100 for each.

The results of the algorithm will depend heavily on the evaluation period you select. For example, if you only chose 1 day, and that day happened to be an outlier in terms of either having really high or really low usage compared to your average, you might buy too much or too little. Similarly, if you choose to long a period, say a year, and you have steadily increasing usage over time, the earlier months will pull down the recommended quantity and you may end up purchasing too little.

## Setting Up the Infrastructure

1) Deploy the `price_list_infrastructure.template` CloudFormation stack.
2) Download the DynamoDB price list bulk API data from [here](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonDynamoDB/current/index.csv)
3) Upload it to the bucket that was created by the CloudFormation stack with the prefix `dynamodb_raw`, making the full object name `dynamodb_raw/index.csv`.
4) Run the `ddb_price_list_reserved_capacity_insert_into.sql` query in Athena. It will transform and load the raw price list data for use in the calculation.
5) This project assumes you have a Glue table already set up with your CUR data. Based on the column names, partitions, etc. that you have setup, you'll need to update those values in the `ddb_price_list_reserved_capacity_recommendations.sql` file. You can use [this project](https://github.com/bamcis-io/AWSCURManager) to curate your CUR files and create Glue databases and tables for them. 
6) Update the `start_date`, `end_date`, and `accountid` properties in the 'variables` section to align with what period of time you're evaluating (recommend a 30 day period where you haven't previously purchased any reserved capacity) as well as the targetted account where the usage occured (which is very likely different than you master payer account id).
7) Run the `ddb_price_list_reserved_capacity_recommendations.sql` query in Athena. The output will provide recommendations for the different permutations of purchasing options. For example, you have DynamoDB usage in us-east-1 and us-west-2. The query will give you data on purchasing `WriteCapacity-Hrs`, `ReadCapacity-Hrs`, `USW2-WriteCapacity-Hrs`, and `USW2-ReadCapacity-Hrs` for both 1 and 3 year terms.
8) You'll get details on recommended number of blocks of 100 units to buy, cost savings percentages, total savings during the lease period, etc.

## Explanation of Columns

### Price List Data
These are the columns in the price list data table:

- **sku** - The overall product sku, this is common between on demand and reserved terms
- **offertermcode** - The code that corresponds with the offer term, i.e. one year or three year
- **ratecode**  - The combination of the sku, offertermcode, and the specific rate, with the rate corresponding to a purchaseoption. DynamoDB only has a Heavy Utilization purchase option (i.e. all upfront).
- **platform** - The category or group of the service. For DDB, this is either read or write units, for other services, this is used to identify what component of the service is being identified, like ElastiCache Redis vs Memcached
- **usagetype** - The usage type identifier in the CUR
- **region** - The region code, like us-east-1
- **service** - The service name
- **adjustedpriceperunit** - The recurring charge for the reserved capacity
- **ondemandhourlycost** - The undiscounted on demand cost per unit
- **breakevenpercentage** - The amount of usage you need over the lease term for the reserved capacity to be more cost efficient than on demand
- **upfrontfee** - Any upfront fee associated with buying the reserved capacity
- **leaseterm** - The length of the reserved capacity commitment in years
- **purchaseoption** - Represents the upfront cost model, All Upfront, Partial Upfront, or no Upfront. In some services, like DynamoDB, these are represented as Heavy Utilization, Medium Utilization, and Light Utilization.
- **offeringclass** - Whether the reserved capacity is standard or convertible. Convertible only applies to EC2.
- **key** - A key consisting of the lease term, purchase option, and offering class
- **reservedinstancecost** - The cost of purchasing a unit of the reserved capacity over the lease term. This includes both the upfront cost and the recurring hourly cost.
- **ondemandcostforterm** - The cost of the unit for the lease term with on demand pricing
- **costsavings** - The cost savings over the lease term by using reserved capacity instead of on demand pricing
- **percentsavings** - The percent savings over the lease term

### Recommendation Output
TODO

## Revisions

### 1.0.0
Initial release.
