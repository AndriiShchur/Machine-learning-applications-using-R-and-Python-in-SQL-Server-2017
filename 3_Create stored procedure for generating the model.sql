USE TutorialDB;
DROP TABLE IF EXISTS rental_rx_models;
GO
CREATE TABLE rental_rx_models (
                model_name VARCHAR(30) NOT NULL DEFAULT('default model') PRIMARY KEY,
                model VARBINARY(MAX) NOT NULL
);
GO

-- Stored procedure that trains and generates an R model using the rental_data and a decision tree algorithm

DROP PROCEDURE IF EXISTS generate_rental_rx_model;
go
CREATE PROCEDURE generate_rental_rx_model (@trained_model varbinary(max) OUTPUT)
AS
BEGIN
    EXECUTE sp_execute_external_script
      @language = N'R'
    , @script = N'
        require("RevoScaleR");

			rental_train_data$Holiday = factor(rental_train_data$Holiday);
            rental_train_data$Snow = factor(rental_train_data$Snow);
            rental_train_data$WeekDay = factor(rental_train_data$WeekDay);

        #Create a dtree model and train it using the training data set
        model_dtree <- rxDTree(RentalCount ~ Month + Day + WeekDay + Snow + Holiday, data = rental_train_data);
        #Before saving the model to the DB table, we need to serialize it
        trained_model <- as.raw(serialize(model_dtree, connection=NULL));'

    , @input_data_1 = N'select "RentalCount", "Year", "Month", "Day", "WeekDay", "Snow", "Holiday" from dbo.rental_data where Year < 2015'
    , @input_data_1_name = N'rental_train_data'
    , @params = N'@trained_model varbinary(max) OUTPUT'
    , @trained_model = @trained_model OUTPUT;
END;
GO

-- Save model to table
TRUNCATE TABLE rental_rx_models;

DECLARE @model VARBINARY(MAX);
EXEC generate_rental_rx_model @model OUTPUT;

INSERT INTO rental_rx_models (model_name, model) VALUES('rxDTree', @model);

SELECT * FROM rental_rx_models;


--Stored procedure that takes model name and new data as input parameters and predicts the rental count for the new data

DROP PROCEDURE IF EXISTS predict_rentalcount_new;
GO
CREATE PROCEDURE predict_rentalcount_new (@model VARCHAR(100),@q NVARCHAR(MAX))
AS
BEGIN
    DECLARE @rx_model VARBINARY(MAX) = (SELECT model FROM rental_rx_models WHERE model_name = @model);
    EXECUTE sp_execute_external_script
        @language = N'R'
        , @script = N'
            require("RevoScaleR");

            #The InputDataSet contains the new data passed to this stored proc. We will use this data to predict.
            rentals = InputDataSet;

        #Convert types to factors
            rentals$Holiday = factor(rentals$Holiday);
            rentals$Snow = factor(rentals$Snow);
            rentals$WeekDay = factor(rentals$WeekDay);

            #Before using the model to predict, we need to unserialize it
            rental_model = unserialize(rx_model);

            #Call prediction function
            rental_predictions = rxPredict(rental_model, rentals);'
                , @input_data_1 = @q
        , @output_data_1_name = N'rental_predictions'
                , @params = N'@rx_model varbinary(max)'
                , @rx_model = @rx_model
                WITH RESULT SETS (("RentalCount_Predicted" FLOAT));

END;
GO

--Execute the predict_rentals stored proc and pass the modelname and a query string with a set of features we want to use to predict the rental count

EXEC dbo.predict_rentalcount_new @model = 'rxDTree',
       @q ='SELECT CONVERT(INT, 3) AS Month, CONVERT(INT, 24) AS Day, CONVERT(INT, 4) AS WeekDay, CONVERT(INT, 1) AS Snow, CONVERT(INT, 1) AS Holiday';
GO


---RevoScaleR 

USE TutorialDB;

--STEP 1 - Setup model table for storing the model
DROP TABLE IF EXISTS rental_models;
GO
CREATE TABLE rental_models (
                model_name VARCHAR(30) NOT NULL DEFAULT('default model'),
                lang VARCHAR(30),
				model VARBINARY(MAX),
				native_model VARBINARY(MAX),
				PRIMARY KEY (model_name, lang)

);
GO


--STEP 2 - Train model using RevoscaleR
DROP PROCEDURE IF EXISTS generate_rental_R_native_model;
go
CREATE PROCEDURE generate_rental_R_native_model (@model_type varchar(30), @trained_model varbinary(max) OUTPUT)
AS
BEGIN
    EXECUTE sp_execute_external_script
      @language = N'R'
    , @script = N'
require("RevoScaleR")

rental_train_data$Holiday = factor(rental_train_data$Holiday);
rental_train_data$Snow = factor(rental_train_data$Snow);
rental_train_data$WeekDay = factor(rental_train_data$WeekDay);

if(model_type == "linear") {
	#Create a dtree model and train it using the training data set
	model_dtree <- rxDTree(RentalCount ~ Month + Day + WeekDay + Snow + Holiday, data = rental_train_data);
	trained_model <- rxSerializeModel(model_dtree, realtimeScoringOnly = TRUE);
	}

if(model_type == "dtree") {
	model_linmod <- rxLinMod(RentalCount ~ Month + Day + WeekDay + Snow + Holiday, data = rental_train_data);
	#Before saving the model to the DB table, we need to serialize it. This time, as a native scoring model
	trained_model <- rxSerializeModel(model_linmod, realtimeScoringOnly = TRUE);
	}
'

    , @input_data_1 = N'select "RentalCount", "Year", "Month", "Day", "WeekDay", "Snow", "Holiday" from dbo.rental_data where Year < 2015'
    , @input_data_1_name = N'rental_train_data'
    , @params = N'@trained_model varbinary(max) OUTPUT, @model_type varchar(30)'
	, @model_type = @model_type
    , @trained_model = @trained_model OUTPUT;
END;
GO

--STEP 3 - Save model to table

--Line of code to empty table with models
--TRUNCATE TABLE rental_models;

--Save Linear model to table
DECLARE @model VARBINARY(MAX);
EXEC generate_rental_R_native_model "linear", @model OUTPUT;
INSERT INTO rental_models (model_name, native_model, lang) VALUES('linear_model', @model, 'R');

--Save DTree model to table
DECLARE @model2 VARBINARY(MAX);
EXEC generate_rental_R_native_model "dtree", @model2 OUTPUT;
INSERT INTO rental_models (model_name, native_model, lang) VALUES('dtree_model', @model2, 'R');

-- Look at the models in the table
SELECT * FROM rental_models;

GO
-- STEP 4  - Use the native PREDICT (native scoring) to predict number of rentals for both models
--Now lets predict using native scoring with linear model
DECLARE @model VARBINARY(MAX) = (SELECT TOP(1) native_model FROM dbo.rental_models WHERE model_name = 'linear_model' AND lang = 'R');
SELECT d.*, p.* FROM PREDICT(MODEL = @model, DATA = dbo.rental_data AS d) WITH(RentalCount_Pred float) AS p;
GO

--Native scoring with dtree model
DECLARE @model VARBINARY(MAX) = (SELECT TOP(1) native_model FROM dbo.rental_models WHERE model_name = 'dtree_model' AND lang = 'R');
SELECT d.*, p.* FROM PREDICT(MODEL = @model, DATA = dbo.rental_data AS d) WITH(RentalCount_Pred float) AS p;
GO