#' Get feature importance using the permutation method
#'
#' Calculates feature importance using a trained model and test data. Requires
#' the `future.apply` package.
#'
#' @inheritParams run_ml
#' @inheritParams calc_perf_metrics
#' @inheritParams group_correlated_features
#' @param nperms number of permutations to perform (default: `100`).
#' @param groups Vector of feature names to group together during permutation.
#'   Each element should be a string with feature names separated by a pipe
#'   character (`|`). If this is `NULL` (default), correlated features will be
#'   grouped together based on `corr_thresh`.
#'
#' @return Data frame with performance metrics for when each feature (or group
#'   of correlated features; `names`) is permuted (`perf_metric`), differences
#'   between the actual test performance metric on and the permuted performance
#'   metric (`perf_metric_diff`; test minus permuted performance), and the
#'   p-value (`pvalue`: the probability of obtaining the actual performance
#'   value under the null hypothesis). Features with a larger `perf_metric_diff`
#'   are more important. The performance metric name (`perf_metric_name`) and
#'   seed (`seed`) are also returned.
#'
#' @details
#' For permutation tests, the p-value is the number of permutation statistics
#' that are greater than the test statistic, divided by the number of
#' permutations. In our case, the permutation statistic is the model performance
#' (e.g. AUROC) after randomizing the order of observations for one feature, and
#' the test statistic is the actual performance on the test data. By default we
#' perform 100 permutations per feature; increasing this will increase the
#' precision of estimating the null distribution, but also increases runtime.
#' The p-value represents the probability of obtaining the actual performance in
#' the event that the null hypothesis is true, where the null hypothesis is that
#' the feature is not important for model performance.
#'
#' We strongly recommend providing multiple cores to speed up computation time.
#' See [our vignette on parallel processing](http://www.schlosslab.org/mikropml/articles/parallel.html)
#' for more details.
#'
#' @examples
#' \dontrun{
#' # If you called `run_ml()` with `feature_importance = FALSE` (the default),
#' # you can use `get_feature_importance()` later as long as you have the
#' # trained model and test data.
#' results <- run_ml(otu_small, "glmnet", kfold = 2, cv_times = 2)
#' names(results$trained_model$trainingData)[1] <- "dx"
#' feat_imp <- get_feature_importance(results$trained_model,
#'   results$trained_model$trainingData,
#'   results$test_data,
#'   "dx",
#'   multiClassSummary,
#'   "AUC",
#'   class_probs = TRUE,
#'   method = "glmnet"
#' )
#'
#' # We strongly recommend providing multiple cores to speed up computation time.
#' # Do this before calling `get_feature_importance()`.
#' doFuture::registerDoFuture()
#' future::plan(future::multicore, workers = 2)
#'
#' # Optionally, you can group features together with a custom grouping
#' feat_imp <- get_feature_importance(results$trained_model,
#'   results$trained_model$trainingData,
#'   results$test_data,
#'   "dx",
#'   multiClassSummary,
#'   "AUC",
#'   class_probs = TRUE,
#'   method = "glmnet",
#'   groups = c(
#'     "Otu00007", "Otu00008", "Otu00009", "Otu00011", "Otu00012",
#'     "Otu00015", "Otu00016", "Otu00018", "Otu00019", "Otu00020", "Otu00022",
#'     "Otu00023", "Otu00025", "Otu00028", "Otu00029", "Otu00030", "Otu00035",
#'     "Otu00036", "Otu00037", "Otu00038", "Otu00039", "Otu00040", "Otu00047",
#'     "Otu00050", "Otu00052", "Otu00054", "Otu00055", "Otu00056", "Otu00060",
#'     "Otu00003|Otu00002|Otu00005|Otu00024|Otu00032|Otu00041|Otu00053",
#'     "Otu00014|Otu00021|Otu00017|Otu00031|Otu00057",
#'     "Otu00013|Otu00006", "Otu00026|Otu00001|Otu00034|Otu00048",
#'     "Otu00033|Otu00010",
#'     "Otu00042|Otu00004", "Otu00043|Otu00027|Otu00049", "Otu00051|Otu00045",
#'     "Otu00058|Otu00044", "Otu00059|Otu00046"
#'   )
#' )
#'
#' # the function can show a progress bar if you have the `progressr` package installed.
#' ## optionally, specify the progress bar format:
#' progressr::handlers(progressr::handler_progress(
#'   format = ":message :bar :percent | elapsed: :elapsed | eta: :eta",
#'   clear = FALSE,
#'   show_after = 0
#' ))
#' ## tell progressr to always report progress
#' progressr::handlers(global = TRUE)
#' ## run the function and watch the live progress udpates
#' feat_imp <- get_feature_importance(results$trained_model,
#'   results$trained_model$trainingData,
#'   results$test_data,
#'   "dx",
#'   multiClassSummary,
#'   "AUC",
#'   class_probs = TRUE,
#'   method = "glmnet"
#' )
#'
#' # You can specify any correlation method supported by `stats::cor`:
#' feat_imp <- get_feature_importance(results$trained_model,
#'   results$trained_model$trainingData,
#'   results$test_data,
#'   "dx",
#'   multiClassSummary,
#'   "AUC",
#'   class_probs = TRUE,
#'   method = "glmnet",
#'   corr_method = "pearson"
#' )
#' }
#'
#' @export
#' @author Begüm Topçuoğlu, \email{topcuoglu.begum@@gmail.com}
#' @author Zena Lapp, \email{zenalapp@@umich.edu}
#' @author Kelly Sovacool, \email{sovacool@@umich.edu}
get_feature_importance <- function(trained_model, test_data,
                                   outcome_colname, perf_metric_function,
                                   perf_metric_name, class_probs, method,
                                   seed = NA, corr_thresh = 1, groups = NULL,
                                   nperms = 100, corr_method = "spearman") {
  abort_packages_not_installed("future.apply")

  # get outcome and features
  split_dat <- split_outcome_features(test_data, outcome_colname)
  outcome <- split_dat$outcome
  features <- split_dat$features

  if (is.null(groups)) {
    groups <- group_correlated_features(features, corr_thresh, corr_method = corr_method)
  }

  test_perf_value <- calc_perf_metrics(
    test_data,
    trained_model,
    outcome_colname,
    perf_metric_function,
    class_probs
  )[[perf_metric_name]]

  nsteps <- nperms * length(groups)
  progbar <- NULL
  if (isTRUE(check_packages_installed("progressr"))) {
    progbar <- progressr::progressor(
      steps = nsteps,
      message = "Feature importance"
    )
  }

  imps <- future.apply::future_lapply(groups, function(feat) {
    return(
      find_permuted_perf_metric(
        test_data,
        trained_model,
        outcome_colname,
        perf_metric_function,
        perf_metric_name,
        class_probs,
        feat,
        test_perf_value,
        nperms = nperms,
        progbar = progbar
      )
    )
  }, future.seed = seed) %>%
    dplyr::bind_rows()

  return(as.data.frame(imps) %>%
    dplyr::mutate(
      names = factor(groups),
      method = method,
      perf_metric_name = perf_metric_name,
      seed = seed
    ))
}

#' Get permuted performance metric difference for a single feature
#' (or group of features)
#'
#' Requires the `future.apply` package
#'
#' @param feat feature or group of correlated features to permute.
#' @param test_perf_value value of the true performance metric on the held-out
#'   test data.
#' @param progbar optional progress bar (default: `NULL`)
#' @inheritParams run_ml
#' @inheritParams get_feature_importance
#'
#' @return vector of mean permuted performance and mean difference between test
#'   and permuted performance (test minus permuted performance)
#' @noRd
#' @author Begüm Topçuoğlu, \email{topcuoglu.begum@@gmail.com}
#' @author Zena Lapp, \email{zenalapp@@umich.edu}
#' @author Kelly Sovacool, \email{sovacool@@umich.edu}
#'
find_permuted_perf_metric <- function(test_data, trained_model, outcome_colname,
                                      perf_metric_function, perf_metric_name,
                                      class_probs, feat,
                                      test_perf_value,
                                      nperms = 100, progbar = NULL) {
  # The code below uses a bunch of base R subsetting that doesn't work with tibbles.
  # We should probably refactor those to use tidyverse functions instead,
  # but for now this is a temporary fix.
  test_data <- as.data.frame(test_data)

  # permute grouped features together
  fs <- strsplit(feat, "\\|")[[1]]
  # only include ones in the test data split
  fs <- fs[fs %in% colnames(test_data)]
  # get the new performance metric and performance metric differences
  n_rows <- nrow(test_data)
  perm_perfs <- sapply(seq(1, nperms), function(x) {
    permuted_test_data <- test_data
    # this strategy works for any number of features
    rows_shuffled <- sample(n_rows)
    permuted_test_data[, fs] <- permuted_test_data[rows_shuffled, fs]
    pbtick(progbar)
    return(
      calc_perf_metrics(
        permuted_test_data,
        trained_model,
        outcome_colname,
        perf_metric_function,
        class_probs
      )[[perf_metric_name]]
    )
  })
  mean_perm_perf <- mean(perm_perfs)
  return(c(
    perf_metric = mean_perm_perf,
    perf_metric_diff = test_perf_value - mean_perm_perf,
    pvalue = calc_pvalue(perm_perfs, test_perf_value)
  ))
}
