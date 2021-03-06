#' @include reexport-promises.R utils.R
NULL

domain <- function(client, domain_name) {
  protocol <- client$.__protocol__
  members_names <- names(c(
    protocol$list_commands(domain_name),
    protocol$list_events(domain_name),
    protocol$list_types(domain_name)
  ))

  CustomDomain <- R6::R6Class(
    domain_name,
    inherit = Domain,
    public = list(
      initialize = function(client, domain) {
        super$initialize(client, domain)
        protocol <- client$.__protocol__
        commands <- protocol$list_commands(domain)
        events <- protocol$list_events(domain)
        types <- protocol$list_types(domain)
        purrr::iwalk(commands, function(command, name) {
          self[[name]] <- private$.build_command(command, name)
        })
        purrr::iwalk(events, function(event, name) {
          self[[name]] <- private$.build_event_listener(event, name)
        })
      }
    )
  )

  purrr::walk(members_names, ~ CustomDomain$set("public", .x, NULL))
  CustomDomain$new(client, domain_name)
}

Domain <- R6::R6Class(
  "Domain",
  public = list(
    initialize = function(client, domain) {
      self$.__client__ <- client
      private$.domain_name <- domain
    },
    print = function() {
      utils::browseURL(paste0("https://chromedevtools.github.io/devtools-protocol/tot/", private$.domain_name))
      invisible(self)
    },
    .__client__ = NULL
  ),
  private = list(
    .domain_name = NULL,
    .build_command = function(method_to_be_sent, name) {
      # environment of the current fonction to get
      # `method_to_be_sent` when needed
      fn_env <- rlang::current_env()

      fun <- function() {
        params_to_be_sent <-
          rlang::fn_fmls_names() %>% # pick the fun arguments
          utils::head(-1) %>% # remove the callback argument
          rlang::env_get_list(nms = ., inherit = TRUE) %>% # retrieve values
          purrr::discard(~ purrr::is_null(.x)) # remove arguments identical to NULL

        if(!is.null(callback)) {
          callback <- rlang::as_function(callback)
        }
        # since the function parameters are not controlled,
        # there might be some conflicts between CDP parameters and `method_to_be_sent`
        # Therefore, we use env_get() to retrieve the correct `method_to_be_sent`
        self$.__client__$send(
            rlang::env_get(env = fn_env, nm = "method_to_be_sent"),
            params = params_to_be_sent,
            onresponse = callback
          )
      }
      formals(fun) <- self$.__client__$.__protocol__$get_formals_for_command(private$.domain_name, name)
      fun
    },
    .build_event_listener = function(event_to_listen, name) {
      fun <- function() {
        if(!is.null(callback)) {
          callback <- rlang::as_function(callback)
        }
        predicates_list <-
          rlang::fn_fmls_names() %>% # pick the fun arguments
          utils::head(-1) %>% # remove the callback argument
          rlang::env_get_list(nms = ., inherit = TRUE) %>% # retrieve arguments values
          purrr::discard(~ purrr::is_null(.x)) # remove arguments identical to NULL

        # if there is no predicate function in the list, return early
        if(length(predicates_list) == 0L) {
          return(self$.__client__$on(event_to_listen, callback = callback))
        }

        caller_env <- rlang::caller_env()
        predicate_fun <-
          predicates_list %>%
          purrr::map(as_predicate, env = caller_env) %>% # transform the arguments to predicate
          combine_predicates()

        # if callback is NULL, we must return a promise
        if(is.null(callback)) {
          return(promises::promise(function(resolve, reject) {
            rm_listener <- NULL
            rm_listener <- self$.__client__$on(event_to_listen, callback = function(result) {
              if(predicate_fun(result)) {
                rm_listener()
                resolve(result)
              }
            })
          }))
        }

        # Now, we know that we have to use a listener and return the function
        # that removes this listener. We also have to ensure that this function
        # sends back the original callback function
        callback <- rlang::as_function(callback)
        rm_listener <- NULL
        out <- function() {
          rm_listener()
          invisible(callback)
        }
        callback_wrapper <- function(result) {
          if(predicate_fun(result)) {
            callback(result)
          }
          rm_listener()
        }
        callback_wrapper <- new_callback_wrapper(callback_wrapper, callback)
        rm_listener <- self$.__client__$on(event_to_listen, callback = callback_wrapper)

        # Now, return the function that removes the listener and returns the original callback
        invisible(out)
      }
      formals(fun) <- self$.__client__$.__protocol__$get_formals_for_event(private$.domain_name, name)
      fun
    }
  )
)

