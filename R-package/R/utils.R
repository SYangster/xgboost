#
# This file is for the low level reusable utility functions
# that are not supposed to be visible to a user.
#

#
# General helper utilities ----------------------------------------------------
#

# SQL-style NVL shortcut.
NVL <- function(x, val) {
  if (is.null(x))
    return(val)
  if (is.vector(x)) {
    x[is.na(x)] <- val
    return(x)
  }
  if (typeof(x) == 'closure')
    return(x)
  stop("typeof(x) == ", typeof(x), " is not supported by NVL")
}

# List of classification and ranking objectives
.CLASSIFICATION_OBJECTIVES <- function() {
  return(c('binary:logistic', 'binary:logitraw', 'binary:hinge', 'multi:softmax',
           'multi:softprob', 'rank:pairwise', 'rank:ndcg', 'rank:map'))
}


#
# Low-level functions for boosting --------------------------------------------
#

# Merges booster params with whatever is provided in ...
# plus runs some checks
check.booster.params <- function(params, ...) {
  if (!identical(class(params), "list"))
    stop("params must be a list")

  # in R interface, allow for '.' instead of '_' in parameter names
  names(params) <- gsub(".", "_", names(params), fixed = TRUE)

  # merge parameters from the params and the dots-expansion
  dot_params <- list(...)
  names(dot_params) <- gsub(".", "_", names(dot_params), fixed = TRUE)
  if (length(intersect(names(params),
                       names(dot_params))) > 0)
    stop("Same parameters in 'params' and in the call are not allowed. Please check your 'params' list.")
  params <- c(params, dot_params)

  # providing a parameter multiple times makes sense only for 'eval_metric'
  name_freqs <- table(names(params))
  multi_names <- setdiff(names(name_freqs[name_freqs > 1]), 'eval_metric')
  if (length(multi_names) > 0) {
    warning("The following parameters were provided multiple times:\n\t",
            paste(multi_names, collapse = ', '), "\n  Only the last value for each of them will be used.\n")
    # While xgboost internals would choose the last value for a multiple-times parameter,
    # enforce it here in R as well (b/c multi-parameters might be used further in R code,
    # and R takes the 1st value when multiple elements with the same name are present in a list).
    for (n in multi_names) {
      del_idx <- which(n == names(params))
      del_idx <- del_idx[-length(del_idx)]
      params[[del_idx]] <- NULL
    }
  }

  # for multiclass, expect num_class to be set
  if (typeof(params[['objective']]) == "character" &&
      substr(NVL(params[['objective']], 'x'), 1, 6) == 'multi:' &&
      as.numeric(NVL(params[['num_class']], 0)) < 2) {
        stop("'num_class' > 1 parameter must be set for multiclass classification")
  }

  # monotone_constraints parser

  if (!is.null(params[['monotone_constraints']]) &&
      typeof(params[['monotone_constraints']]) != "character") {
        vec2str <- paste(params[['monotone_constraints']], collapse = ',')
        vec2str <- paste0('(', vec2str, ')')
        params[['monotone_constraints']] <- vec2str
  }

  # interaction constraints parser (convert from list of column indices to string)
  if (!is.null(params[['interaction_constraints']]) &&
      typeof(params[['interaction_constraints']]) != "character") {
    # check input class
    if (!identical(class(params[['interaction_constraints']]), 'list')) stop('interaction_constraints should be class list')
    if (!all(unique(sapply(params[['interaction_constraints']], class)) %in% c('numeric', 'integer'))) {
      stop('interaction_constraints should be a list of numeric/integer vectors')
    }

    # recast parameter as string
    interaction_constraints <- sapply(params[['interaction_constraints']], function(x) paste0('[', paste(x, collapse = ','), ']'))
    params[['interaction_constraints']] <- paste0('[', paste(interaction_constraints, collapse = ','), ']')
  }
  return(params)
}


# Performs some checks related to custom objective function.
# WARNING: has side-effects and can modify 'params' and 'obj' in its calling frame
check.custom.obj <- function(env = parent.frame()) {
  if (!is.null(env$params[['objective']]) && !is.null(env$obj))
    stop("Setting objectives in 'params' and 'obj' at the same time is not allowed")

  if (!is.null(env$obj) && typeof(env$obj) != 'closure')
    stop("'obj' must be a function")

  # handle the case when custom objective function was provided through params
  if (!is.null(env$params[['objective']]) &&
      typeof(env$params$objective) == 'closure') {
    env$obj <- env$params$objective
    env$params$objective <- NULL
  }
}

# Performs some checks related to custom evaluation function.
# WARNING: has side-effects and can modify 'params' and 'feval' in its calling frame
check.custom.eval <- function(env = parent.frame()) {
  if (!is.null(env$params[['eval_metric']]) && !is.null(env$feval))
    stop("Setting evaluation metrics in 'params' and 'feval' at the same time is not allowed")

  if (!is.null(env$feval) && typeof(env$feval) != 'closure')
    stop("'feval' must be a function")

  # handle a situation when custom eval function was provided through params
  if (!is.null(env$params[['eval_metric']]) &&
      typeof(env$params$eval_metric) == 'closure') {
    env$feval <- env$params$eval_metric
    env$params$eval_metric <- NULL
  }

  # require maximize to be set when custom feval and early stopping are used together
  if (!is.null(env$feval) &&
      is.null(env$maximize) && (
        !is.null(env$early_stopping_rounds) ||
        has.callbacks(env$callbacks, 'cb.early.stop')))
    stop("Please set 'maximize' to indicate whether the evaluation metric needs to be maximized or not")
}


# Update a booster handle for an iteration with dtrain data
xgb.iter.update <- function(booster_handle, dtrain, iter, obj) {
  if (!identical(class(booster_handle), "xgb.Booster.handle")) {
    stop("booster_handle must be of xgb.Booster.handle class")
  }
  if (!inherits(dtrain, "xgb.DMatrix")) {
    stop("dtrain must be of xgb.DMatrix class")
  }

  if (is.null(obj)) {
    .Call(XGBoosterUpdateOneIter_R, booster_handle, as.integer(iter), dtrain)
  } else {
    pred <- predict(booster_handle, dtrain, outputmargin = TRUE, training = TRUE,
                    ntreelimit = 0)
    gpair <- obj(pred, dtrain)
    .Call(XGBoosterBoostOneIter_R, booster_handle, dtrain, gpair$grad, gpair$hess)
  }
  return(TRUE)
}


# Evaluate one iteration.
# Returns a named vector of evaluation metrics
# with the names in a 'datasetname-metricname' format.
xgb.iter.eval <- function(booster_handle, watchlist, iter, feval) {
  if (!identical(class(booster_handle), "xgb.Booster.handle"))
    stop("class of booster_handle must be xgb.Booster.handle")

  if (length(watchlist) == 0)
    return(NULL)

  evnames <- names(watchlist)
  if (is.null(feval)) {
    msg <- .Call(XGBoosterEvalOneIter_R, booster_handle, as.integer(iter), watchlist, as.list(evnames))
    mat <- matrix(strsplit(msg, '\\s+|:')[[1]][-1], nrow = 2)
    res <- structure(as.numeric(mat[2, ]), names = mat[1, ])
  } else {
    res <- sapply(seq_along(watchlist), function(j) {
      w <- watchlist[[j]]
      ## predict using all trees
      preds <- predict(booster_handle, w, outputmargin = TRUE, iterationrange = c(1, 1))
      eval_res <- feval(preds, w)
      out <- eval_res$value
      names(out) <- paste0(evnames[j], "-", eval_res$metric)
      out
    })
  }
  return(res)
}


#
# Helper functions for cross validation ---------------------------------------
#

# Possibly convert the labels into factors, depending on the objective.
# The labels are converted into factors only when the given objective refers to the classification
# or ranking tasks.
convert.labels <- function(labels, objective_name) {
  if (objective_name %in% .CLASSIFICATION_OBJECTIVES()) {
    return(as.factor(labels))
  } else {
    return(labels)
  }
}

# Generates random (stratified if needed) CV folds
generate.cv.folds <- function(nfold, nrows, stratified, label, params) {

  # cannot do it for rank
  objective <- params$objective
  if (is.character(objective) && strtrim(objective, 5) == 'rank:') {
    stop("\n\tAutomatic generation of CV-folds is not implemented for ranking!\n",
         "\tConsider providing pre-computed CV-folds through the 'folds=' parameter.\n")
  }
  # shuffle
  rnd_idx <- sample.int(nrows)
  if (stratified &&
      length(label) == length(rnd_idx)) {
    y <- label[rnd_idx]
    # WARNING: some heuristic logic is employed to identify classification setting!
    #  - For classification, need to convert y labels to factor before making the folds,
    #    and then do stratification by factor levels.
    #  - For regression, leave y numeric and do stratification by quantiles.
    if (is.character(objective)) {
      y <- convert.labels(y, params$objective)
    } else {
      # If no 'objective' given in params, it means that user either wants to
      # use the default 'reg:squarederror' objective or has provided a custom
      # obj function.  Here, assume classification setting when y has 5 or less
      # unique values:
      if (length(unique(y)) <= 5) {
        y <- factor(y)
      }
    }
    folds <- xgb.createFolds(y = y, k = nfold)
  } else {
    # make simple non-stratified folds
    kstep <- length(rnd_idx) %/% nfold
    folds <- list()
    for (i in seq_len(nfold - 1)) {
      folds[[i]] <- rnd_idx[seq_len(kstep)]
      rnd_idx <- rnd_idx[-seq_len(kstep)]
    }
    folds[[nfold]] <- rnd_idx
  }
  return(folds)
}

# Creates CV folds stratified by the values of y.
# It was borrowed from caret::createFolds and simplified
# by always returning an unnamed list of fold indices.
xgb.createFolds <- function(y, k) {
  if (is.numeric(y)) {
    ## Group the numeric data based on their magnitudes
    ## and sample within those groups.

    ## When the number of samples is low, we may have
    ## issues further slicing the numeric data into
    ## groups. The number of groups will depend on the
    ## ratio of the number of folds to the sample size.
    ## At most, we will use quantiles. If the sample
    ## is too small, we just do regular unstratified
    ## CV
    cuts <- floor(length(y) / k)
    if (cuts < 2) cuts <- 2
    if (cuts > 5) cuts <- 5
    y <- cut(y,
             unique(stats::quantile(y, probs = seq(0, 1, length = cuts))),
             include.lowest = TRUE)
  }

  if (k < length(y)) {
    ## reset levels so that the possible levels and
    ## the levels in the vector are the same
    y <- factor(as.character(y))
    numInClass <- table(y)
    foldVector <- vector(mode = "integer", length(y))

    ## For each class, balance the fold allocation as far
    ## as possible, then resample the remainder.
    ## The final assignment of folds is also randomized.
    for (i in seq_along(numInClass)) {
      ## create a vector of integers from 1:k as many times as possible without
      ## going over the number of samples in the class. Note that if the number
      ## of samples in a class is less than k, nothing is produced here.
      seqVector <- rep(seq_len(k), numInClass[i] %/% k)
      ## add enough random integers to get  length(seqVector) == numInClass[i]
      if (numInClass[i] %% k > 0) seqVector <- c(seqVector, sample.int(k, numInClass[i] %% k))
      ## shuffle the integers for fold assignment and assign to this classes's data
      ## seqVector[sample.int(length(seqVector))] is used to handle length(seqVector) == 1
      foldVector[y == dimnames(numInClass)$y[i]] <- seqVector[sample.int(length(seqVector))]
    }
  } else {
    foldVector <- seq(along = y)
  }

  out <- split(seq(along = y), foldVector)
  names(out) <- NULL
  out
}


#
# Deprectaion notice utilities ------------------------------------------------
#

#' Deprecation notices.
#'
#' At this time, some of the parameter names were changed in order to make the code style more uniform.
#' The deprecated parameters would be removed in the next release.
#'
#' To see all the current deprecated and new parameters, check the \code{xgboost:::depr_par_lut} table.
#'
#' A deprecation warning is shown when any of the deprecated parameters is used in a call.
#' An additional warning is shown when there was a partial match to a deprecated parameter
#' (as R is able to partially match parameter names).
#'
#' @name xgboost-deprecated
NULL

#' Do not use \code{\link[base]{saveRDS}} or \code{\link[base]{save}} for long-term archival of
#' models. Instead, use \code{\link{xgb.save}} or \code{\link{xgb.save.raw}}.
#'
#' It is a common practice to use the built-in \code{\link[base]{saveRDS}} function (or
#' \code{\link[base]{save}}) to persist R objects to the disk. While it is possible to persist
#' \code{xgb.Booster} objects using \code{\link[base]{saveRDS}}, it is not advisable to do so if
#' the model is to be accessed in the future. If you train a model with the current version of
#' XGBoost and persist it with \code{\link[base]{saveRDS}}, the model is not guaranteed to be
#' accessible in later releases of XGBoost. To ensure that your model can be accessed in future
#' releases of XGBoost, use \code{\link{xgb.save}} or \code{\link{xgb.save.raw}} instead.
#'
#' @details
#' Use \code{\link{xgb.save}} to save the XGBoost model as a stand-alone file. You may opt into
#' the JSON format by specifying the JSON extension. To read the model back, use
#' \code{\link{xgb.load}}.
#'
#' Use \code{\link{xgb.save.raw}} to save the XGBoost model as a sequence (vector) of raw bytes
#' in a future-proof manner. Future releases of XGBoost will be able to read the raw bytes and
#' re-construct the corresponding model. To read the model back, use \code{\link{xgb.load.raw}}.
#' The \code{\link{xgb.save.raw}} function is useful if you'd like to persist the XGBoost model
#' as part of another R object.
#'
#' Note: Do not use \code{\link{xgb.serialize}} to store models long-term. It persists not only the
#' model but also internal configurations and parameters, and its format is not stable across
#' multiple XGBoost versions. Use \code{\link{xgb.serialize}} only for checkpointing.
#'
#' For more details and explanation about model persistence and archival, consult the page
#' \url{https://xgboost.readthedocs.io/en/latest/tutorials/saving_model.html}.
#'
#' @examples
#' data(agaricus.train, package='xgboost')
#' bst <- xgboost(data = agaricus.train$data, label = agaricus.train$label, max_depth = 2,
#'                eta = 1, nthread = 2, nrounds = 2, objective = "binary:logistic")
#'
#' # Save as a stand-alone file; load it with xgb.load()
#' xgb.save(bst, 'xgb.model')
#' bst2 <- xgb.load('xgb.model')
#'
#' # Save as a stand-alone file (JSON); load it with xgb.load()
#' xgb.save(bst, 'xgb.model.json')
#' bst2 <- xgb.load('xgb.model.json')
#' if (file.exists('xgb.model.json')) file.remove('xgb.model.json')
#'
#' # Save as a raw byte vector; load it with xgb.load.raw()
#' xgb_bytes <- xgb.save.raw(bst)
#' bst2 <- xgb.load.raw(xgb_bytes)
#'
#' # Persist XGBoost model as part of another R object
#' obj <- list(xgb_model_bytes = xgb.save.raw(bst), description = "My first XGBoost model")
#' # Persist the R object. Here, saveRDS() is okay, since it doesn't persist
#' # xgb.Booster directly. What's being persisted is the future-proof byte representation
#' # as given by xgb.save.raw().
#' saveRDS(obj, 'my_object.rds')
#' # Read back the R object
#' obj2 <- readRDS('my_object.rds')
#' # Re-construct xgb.Booster object from the bytes
#' bst2 <- xgb.load.raw(obj2$xgb_model_bytes)
#' if (file.exists('my_object.rds')) file.remove('my_object.rds')
#'
#' @name a-compatibility-note-for-saveRDS-save
NULL

# Lookup table for the deprecated parameters bookkeeping
depr_par_lut <- matrix(c(
  'print.every.n', 'print_every_n',
  'early.stop.round', 'early_stopping_rounds',
  'training.data', 'data',
  'with.stats', 'with_stats',
  'numberOfClusters', 'n_clusters',
  'features.keep', 'features_keep',
  'plot.height', 'plot_height',
  'plot.width', 'plot_width',
  'n_first_tree', 'trees',
  'dummy', 'DUMMY'
), ncol = 2, byrow = TRUE)
colnames(depr_par_lut) <- c('old', 'new')

# Checks the dot-parameters for deprecated names
# (including partial matching), gives a deprecation warning,
# and sets new parameters to the old parameters' values within its parent frame.
# WARNING: has side-effects
check.deprecation <- function(..., env = parent.frame()) {
  pars <- list(...)
  # exact and partial matches
  all_match <- pmatch(names(pars), depr_par_lut[, 1])
  # indices of matched pars' names
  idx_pars <- which(!is.na(all_match))
  if (length(idx_pars) == 0) return()
  # indices of matched LUT rows
  idx_lut <- all_match[idx_pars]
  # which of idx_lut were the exact matches?
  ex_match <- depr_par_lut[idx_lut, 1] %in% names(pars)
  for (i in seq_along(idx_pars)) {
    pars_par <- names(pars)[idx_pars[i]]
    old_par <- depr_par_lut[idx_lut[i], 1]
    new_par <- depr_par_lut[idx_lut[i], 2]
    if (!ex_match[i]) {
      warning("'", pars_par, "' was partially matched to '", old_par, "'")
    }
    .Deprecated(new_par, old = old_par, package = 'xgboost')
    if (new_par != 'NULL') {
      eval(parse(text = paste(new_par, '<-', pars[[pars_par]])), envir = env)
    }
  }
}
