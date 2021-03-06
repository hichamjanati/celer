# Author: Mathurin Massias <mathurin.massias@gmail.com>
#         Alexandre Gramfort <alexandre.gramfort@inria.fr>
#         Joseph Salmon <joseph.salmon@telecom-paristech.fr>
# License: BSD 3 clause

import time
import numpy as np
cimport numpy as np
cimport cython

from cython cimport floating
from libc.math cimport fabs, sqrt

from utils cimport primal_value, dual_value, ST
from utils cimport fdot, fasum, faxpy, fnrm2, fcopy, fscal, fposv


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef floating compute_dual_scaling_sparse(
    int n_features, int n_samples, floating * theta, floating[:] X_data,
    int[:] X_indices, int[:] X_indptr, int ws_size, int * C,
    floating[:] X_mean, bint center) nogil:
    """compute norm(X.T.dot(theta), ord=inf),
    with X restricted to features (columns) with indices in array C.
    if ws_size == n_features, C=np.arange(n_features is used)"""
    cdef floating Xj_theta
    cdef floating scal = 0.
    cdef floating theta_sum = 0.
    cdef int j
    cdef int Cj
    cdef int i
    cdef int startptr
    cdef int endptr
    if center:
        for i in range(n_samples):
            theta_sum += theta[i]

    if ws_size == n_features: # scaling wrt all features
        for j in range(n_features):
            startptr = X_indptr[j]
            endptr = X_indptr[j + 1]
            Xj_theta = 0.
            for i in range(startptr, endptr):
                Xj_theta += X_data[i] * theta[X_indices[i]]
            if center:
                Xj_theta -= theta_sum * X_mean[j]
            Xj_theta = fabs(Xj_theta)
            scal = max(scal, Xj_theta)
    else: # scaling wrt features in C only
        for j in range(ws_size):
            Cj = C[j]
            startptr = X_indptr[Cj]
            endptr = X_indptr[Cj + 1]
            Xj_theta = 0.
            for i in range(startptr, endptr):
                Xj_theta += X_data[i] * theta[X_indices[i]]
            if center:
                Xj_theta -= theta_sum * X_mean[j]

            Xj_theta = fabs(Xj_theta)

            scal = max(scal, Xj_theta)
    return scal


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void set_feature_prios_sparse(int n_features, floating * theta,
                            floating[:] X_data, int[:] X_indices,
                            int[:] X_indptr,
                            floating * norms_X_col,
                            floating * prios) nogil:
    cdef int j
    cdef int i
    cdef floating Xj_theta
    cdef int startptr
    cdef int endptr

    for j in range(n_features):
        if norms_X_col[j] == 0.:
            prios[j] = 10000
            continue
        Xj_theta = 0
        startptr = X_indptr[j]
        endptr = X_indptr[j + 1]
        for i in range(startptr, endptr):
            Xj_theta += theta[X_indices[i]] * X_data[i]
        prios[j] = fabs(fabs(Xj_theta) - 1.) / norms_X_col[j]


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
def celer_sparse(
    floating[:] X_data, int[:] X_indices, int[:] X_indptr, floating[:] X_mean,
    floating[:] y, floating alpha,  floating[:] w_init, int max_iter,
    int max_epochs, int gap_freq=10, float tol_ratio_inner=0.3,
    float tol=1e-6, int p0=100, int screening=0, int verbose=0,
    int verbose_inner=0, int use_accel=1,  int return_ws_size=0,
    int prune=0):

    if floating is double:
        dtype = np.float64
    else:
        dtype = np.float32

    cdef int n_features = w_init.shape[0]
    cdef floating t0 = time.time()
    if p0 > n_features:
        p0 = n_features

    cdef int startptr, endptr

    cdef int n_samples = y.shape[0]
    cdef floating[:] w = np.empty(n_features, dtype=dtype)
    cdef int j  # features
    cdef int i  # samples
    cdef int t  # outer loop
    cdef int inc = 1
    cdef floating tmp
    cdef int ws_size = 0
    cdef floating p_obj
    cdef floating d_obj
    cdef floating highest_d_obj
    cdef floating scal
    cdef floating gap
    cdef bint center = False
    cdef floating X_mean_j
    # cdef floating normalize_sum = 0.0
    cdef floating[:] prios = np.empty(n_features, dtype=dtype)
    cdef floating[:] norms_X_col = np.empty(n_features, dtype=dtype)
    cdef floating[:] R = np.zeros(n_samples, dtype=dtype)

    # center = X_mean.any()
    for j in range(n_features):
        if X_mean[j]:
            center = True
            break

    # compute norms_X_col and R
    fcopy(&n_samples, &y[0], &inc, &R[0], &inc)
    for j in range(n_features):
        w[j] = w_init[j]
        startptr = X_indptr[j]
        endptr = X_indptr[j + 1]
        X_mean_j = X_mean[j]
        tmp = 0.
        for i in range(startptr, endptr):
            tmp += (X_data[i] - X_mean_j) ** 2
        tmp += (n_samples - endptr + startptr) * X_mean_j ** 2
        norms_X_col[j] = sqrt(tmp)

        # R -= np.dot(X[:, j], w)
        if w[j] == 0.:
            continue
        else:
            startptr = X_indptr[j]
            endptr = X_indptr[j + 1]
            for i in range(startptr, endptr):
                R[X_indices[i]] -= w[j] * X_data[i]
            if center:
                for i in range(n_samples):
                    R[i] += X_mean_j * w[j]

    cdef floating norm_y2 = fnrm2(&n_samples, &y[0], &inc) ** 2

    cdef floating[:] times = np.zeros(max_iter, dtype=dtype)
    cdef floating[:] gaps = np.zeros(max_iter, dtype=dtype)
    cdef int[:] epochs = np.zeros(max_iter, dtype=np.int32)
    cdef int[:] ws_sizes = np.zeros(max_iter, dtype=np.int32)

    cdef floating[:] theta = np.zeros(n_samples, dtype=dtype)
    cdef floating[:] theta_inner = np.zeros(n_samples, dtype=dtype)
    # passed to inner solver
    # and potentially used for screening if it gives a better d_obj
    cdef floating d_obj_from_inner = 0.

    cdef int[:] dummy_C = np.zeros(1, dtype=np.int32) # initialize with dummy value
    cdef int[:] all_features = np.arange(n_features, dtype=np.int32)

    for t in range(max_iter):
        # theta = R / (alpha * n_samples)
        fcopy(&n_samples, &R[0], &inc, &theta[0], &inc)
        tmp = 1. / (alpha * n_samples)
        fscal(&n_samples, &tmp, &theta[0], &inc)

        scal = compute_dual_scaling_sparse(
            n_features, n_samples, &theta[0], X_data, X_indices, X_indptr,
            n_features, &dummy_C[0], X_mean, center)

        if scal > 1. :
            tmp = 1. / scal
            fscal(&n_samples, &tmp, &theta[0], &inc)

        d_obj = dual_value(n_samples, alpha, norm_y2, &theta[0],
                           &y[0])

        # also test dual point returned by inner solver after 1st iter:
        if t != 0:
            scal = compute_dual_scaling_sparse(
                n_features, n_samples, &theta_inner[0], X_data, X_indices,
                X_indptr, n_features, &dummy_C[0], X_mean, center)
            if scal > 1.:
                tmp = 1. / scal
                fscal(&n_samples, &tmp, &theta_inner[0], &inc)

            d_obj_from_inner = dual_value(n_samples, alpha, norm_y2,
                                          &theta_inner[0], &y[0])

        if d_obj_from_inner > d_obj:
            d_obj = d_obj_from_inner
            fcopy(&n_samples, &theta_inner[0], &inc, &theta[0], &inc)

        if t == 0 or d_obj > highest_d_obj:
            highest_d_obj = d_obj
            # TODO implement a best_theta

        p_obj = primal_value(alpha, n_samples, &R[0], n_features, &w[0])
        gap = p_obj - highest_d_obj
        gaps[t] = gap
        times[t] = time.time() - t0

        if verbose:
            print("############ Iteration %d  #################" % t)
            print("Primal {:.10f}".format(p_obj))
            print("Dual {:.10f}".format(highest_d_obj))
            print("Log gap %.2e" % gap)

        if gap < tol:
            if verbose:
                print("Early exit, gap: %.2e < %.2e" % (gap, tol))
            break

        set_feature_prios_sparse(n_features, &theta[0],
                          X_data, X_indices, X_indptr,
                          &norms_X_col[0], &prios[0])

        if prune:
            ws_size = 0
            for j in range(n_features):
                if w[j] != 0:
                    prios[j] = -1.
                    ws_size += 1

            ws_size = min(n_features, 2 * ws_size)

            if t == 0:
                ws_size = p0

        else:
            for j in range(n_features):
                if w[j] != 0:
                    prios[j] = - 1
            if t == 0:
                ws_size = p0
            else:
                for j in range(ws_size):
                    prios[C[j]] = -1
                ws_size = min(n_features, 2 * ws_size)

        if ws_size > n_features:
            ws_size = n_features

        ws_sizes[t] = ws_size

        # if ws_size === n_features then argpartition will break:
        if ws_size == n_features:
            C = all_features
        else:
            C = np.argpartition(np.asarray(prios), ws_size)[:ws_size].astype(np.int32)
            C.sort()
        if prune:
            tol_inner = tol_ratio_inner * gap
        else:
            tol_inner = tol

        if verbose:
            print("Solving subproblem with %d constraints" % len(C))
        # calling inner solver which will modify w and R inplace
        epochs[t] = inner_solver_sparse(
            n_samples, n_features, ws_size, X_data, X_indices, X_indptr, X_mean,
            y, alpha, center, w, R, C, theta_inner, norms_X_col,
            norm_y2, tol_inner, max_epochs=max_epochs,
            gap_freq=gap_freq, verbose=verbose_inner,
            use_accel=use_accel)

    if return_ws_size:
        return (np.asarray(w), np.asarray(theta),
                np.asarray(gaps[:t + 1]), np.asarray(times[:t + 1]),
                np.asarray(ws_sizes[:t + 1]))

    return (np.asarray(w), np.asarray(theta),
            np.asarray(gaps[:t + 1]), np.asarray(times[:t + 1]))


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cpdef int inner_solver_sparse(
    int n_samples, int n_features, int ws_size,
    floating[:] X_data, int[:] X_indices, int[:] X_indptr, floating[:] X_mean,
    floating[:] y, floating alpha, bint center, floating[:] w, floating[:] R,
    int[:] C, floating[:] theta, floating[:] norms_X_col,
    floating norm_y2, floating eps, int max_epochs, int gap_freq,
    int verbose=0, int K=6, int use_accel=1):

    if floating is double:
        dtype = np.float64
    else:
        dtype = np.float32

    cdef int startptr
    cdef int endptr

    cdef int i # to iterate over samples.
    cdef int j  # to iterate over features
    cdef int k
    cdef int epoch
    cdef floating old_w_j
    cdef floating w_Cj
    cdef int inc = 1
    # gap related:
    cdef floating gap
    cdef floating[:] gaps = np.zeros(max_epochs // gap_freq, dtype=dtype)

    # cdef floating[:] theta = np.empty(n_samples)
    cdef floating[:] thetaccel = np.empty(n_samples, dtype=dtype)
    cdef floating dual_scale
    cdef floating d_obj
    cdef floating highest_d_obj = 0. # d_obj is always >=0 so this gets replaced
    # at first d_obj computation. highest_d_obj corresponds to theta = 0.
    cdef floating tmp
    cdef floating R_sum
    # acceleration variables:
    cdef floating[:, :] last_K_res = np.empty([K, n_samples], dtype=dtype)
    cdef floating[:, :] U = np.empty([K - 1, n_samples], dtype=dtype)
    cdef floating[:, :] UtU = np.empty([K - 1, K - 1], dtype=dtype)
    cdef floating[:] onesK = np.ones(K - 1, dtype=dtype)
    cdef floating dual_scale_accel
    cdef floating d_obj_accel

    # solving linear system in cython
    # doc at https://software.intel.com/en-us/node/468894
    cdef char char_U = 'U'
    cdef int Kminus1 = K - 1
    cdef int one = 1
    cdef floating sum_z
    cdef int info_dposv


    for epoch in range(max_epochs):
        if epoch % gap_freq == 1:
            # theta = R / (alpha * n_samples)
            fcopy(&n_samples, &R[0], &inc, &theta[0], &inc)
            tmp = 1. / (alpha * n_samples)
            fscal(&n_samples, &tmp, &theta[0], &inc)

            dual_scale = compute_dual_scaling_sparse(
                n_features, n_samples, &theta[0], X_data, X_indices, X_indptr,
                ws_size, &C[0], X_mean, center)

            if dual_scale > 1. :
                tmp = 1. / dual_scale
                fscal(&n_samples, &tmp, &theta[0], &inc)

            d_obj = dual_value(n_samples, alpha, norm_y2, &theta[0],
                               &y[0])

            if use_accel: # also compute accelerated dual_point
                if epoch // gap_freq < K:
                    # last_K_res[it // f_gap] = R:
                    fcopy(&n_samples, &R[0], &inc,
                          &last_K_res[epoch // gap_freq, 0], &inc)
                else:
                    for k in range(K - 1):
                        fcopy(&n_samples, &last_K_res[k + 1, 0], &inc,
                              &last_K_res[k, 0], &inc)
                    fcopy(&n_samples, &R[0], &inc, &last_K_res[K - 1, 0], &inc)
                    for k in range(K - 1):
                        for i in range(n_samples):
                            U[k, i] = last_K_res[k + 1, i] - last_K_res[k, i]

                    for k in range(K - 1):
                        for j in range(k, K - 1):
                            UtU[k, j] = fdot(&n_samples, &U[k, 0], &inc,
                                              &U[j, 0], &inc)
                            UtU[j, k] = UtU[k, j]

                    # refill onesK with ones because it has been overwritten
                    # by dposv
                    for k in range(K - 1):
                        onesK[k] = 1

                    fposv(&char_U, &Kminus1, &one, &UtU[0, 0], &Kminus1,
                           &onesK[0], &Kminus1,
                           &info_dposv)

                    # onesK now holds the solution in x to UtU dot x = onesK
                    if info_dposv != 0:
                        if verbose:
                            print("linear system solving failed")
                        # don't use accel for this iteration
                        for k in range(K - 2):
                            onesK[k] = 0
                        onesK[K - 2] = 1

                    sum_z = 0
                    for k in range(K - 1):
                        sum_z += onesK[k]
                    for k in range(K - 1):
                        onesK[k] /= sum_z

                    for i in range(n_samples):
                        thetaccel[i] = 0.
                    for k in range(K - 1):
                        for i in range(n_samples):
                            thetaccel[i] += onesK[k] * last_K_res[k, i]

                    tmp = 1 / (alpha * n_samples)
                    fscal(&n_samples, &tmp, &thetaccel[0], &inc)

                    dual_scale_accel = compute_dual_scaling_sparse(
                        n_features, n_samples, &thetaccel[0], X_data,
                        X_indices, X_indptr, ws_size, &C[0], X_mean, center)

                    if dual_scale_accel > 1. :
                        tmp = 1. / dual_scale_accel
                        fscal(&n_samples, &tmp, &thetaccel[0], &inc)

                    d_obj_accel = dual_value(n_samples, alpha, norm_y2,
                                             &thetaccel[0], &y[0])

                    if d_obj_accel > d_obj:
                        d_obj = d_obj_accel
                        # theta = theta_accel (theta is defined as
                        # theta_inner in outer loop)
                        fcopy(&n_samples, &thetaccel[0], &inc, &theta[0], &inc)

            if d_obj > highest_d_obj:
                highest_d_obj = d_obj

            # CAUTION: I have not yet written the code to include a best_theta.
            # This is of no consequence as long as screening is not performed. Otherwise dgap and theta might disagree.

            # we pass full w and will ignore zero values
            gap = primal_value(alpha, n_samples, &R[0], n_features,
                               &w[0]) - highest_d_obj
            gaps[epoch / gap_freq] = gap

            if verbose:
                print("Inner epoch %d, gap: %.2e" % (epoch, gap))
                print("primal %.9f" % (gap + highest_d_obj))
            if gap < eps:
                if verbose:
                    print("Inner: early exit at epoch %d, gap: %.2e < %.2e" % \
                        (epoch, gap, eps))
                break

        for k in range(ws_size):
            # update feature k in place, cyclically
            j = C[k]
            if norms_X_col[j] == 0.:
                continue
            old_w_j = w[j]
            X_mean_j = X_mean[j]
            startptr, endptr = X_indptr[j], X_indptr[j + 1]
            for i in range(startptr, endptr):
                w[j] += R[X_indices[i]] * X_data[i] / norms_X_col[j] ** 2
            if center:
                R_sum = 0.
                for i in range(n_samples):
                    R_sum += R[i]
                w[j] -= R_sum * X_mean_j / norms_X_col[j] ** 2

            # perform ST in place:
            w[j] = ST(alpha / norms_X_col[j] ** 2 * n_samples, w[j])

            # R -= (w_j - old_w_j) * (X[:, j] - X_mean[j])
            tmp = w[j] - old_w_j
            if tmp != 0.:
                for i in range(startptr, endptr):
                    R[X_indices[i]] -= tmp *  X_data[i]
                if center:
                    for i in range(n_samples):
                        R[i] += X_mean_j * tmp
    else:
        print("!!! Inner solver did not converge at epoch %d, gap: %.2e > %.2e" % \
            (epoch, gap, eps))

    return epoch
