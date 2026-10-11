import { keepPreviousData, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { employeesApi } from './api';
import type {
  ChangePermissionsInput,
  ChangeRoleInput,
  ChangeStatusInput,
  CreateEmployeeInput,
  EmployeeDetail,
  EmployeeListParams,
  UpdateEmployeeInput,
} from './types';

export const employeeKeys = {
  all: ['admin', 'employees'] as const,
  lists: () => ['admin', 'employees', 'list'] as const,
  list: (params: EmployeeListParams) => ['admin', 'employees', 'list', params] as const,
  detail: (id: string) => ['admin', 'employees', 'detail', id] as const,
  activities: (id: string) => ['admin', 'employees', 'activity', id] as const,
  activity: (id: string, page: number) => ['admin', 'employees', 'activity', id, page] as const,
};

const ACTIVITY_PAGE_SIZE = 25;

// No polling anywhere in this module: data refreshes on navigation, retry or after a mutation.

export function useEmployees(params: EmployeeListParams) {
  return useQuery({
    queryKey: employeeKeys.list(params),
    queryFn: ({ signal }) => employeesApi.list(params, signal), // changed params abort the old request
    staleTime: 60_000,
    refetchOnWindowFocus: false,
    retry: 1,
    placeholderData: keepPreviousData, // keeps the table on screen while the next page loads
  });
}

export function useEmployee(id: string | undefined) {
  return useQuery({
    queryKey: employeeKeys.detail(id ?? ''),
    queryFn: () => employeesApi.get(id ?? ''),
    enabled: Boolean(id),
    staleTime: 30_000,
    refetchOnWindowFocus: false,
    retry: 1,
  });
}

export function useEmployeeActivity(id: string | undefined, page: number) {
  return useQuery({
    queryKey: employeeKeys.activity(id ?? '', page),
    queryFn: () => employeesApi.activity(id ?? '', page, ACTIVITY_PAGE_SIZE),
    enabled: Boolean(id),
    staleTime: 30_000,
    refetchOnWindowFocus: false,
    retry: 1,
    placeholderData: keepPreviousData,
  });
}

/** After any change: the detail comes from the response, lists and the activity trail are refetched. */
function useAfterChange() {
  const qc = useQueryClient();
  return (employee: EmployeeDetail) => {
    qc.setQueryData(employeeKeys.detail(employee.id), employee);
    void qc.invalidateQueries({ queryKey: employeeKeys.lists() });
    void qc.invalidateQueries({ queryKey: employeeKeys.activities(employee.id) });
  };
}

/**
 * `gcTime: 0` on mutations that carry or return secrets (Aadhaar in the request, a temporary password
 * in the response) so React Query's mutation cache does not keep them after the component is done.
 * Pages should also call `reset()` once they have shown or used the result.
 */
export function useCreateEmployee() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: CreateEmployeeInput) => employeesApi.create(input),
    gcTime: 0,
    retry: false,
    onSuccess: ({ employee }) => {
      // Only the employee is cached. `temporaryPassword` stays in the mutation result.
      qc.setQueryData(employeeKeys.detail(employee.id), employee);
      void qc.invalidateQueries({ queryKey: employeeKeys.lists() });
    },
  });
}

export function useUpdateEmployee(id: string) {
  const afterChange = useAfterChange();
  return useMutation({
    mutationFn: (input: UpdateEmployeeInput) => employeesApi.update(id, input),
    gcTime: 0, // the request may contain a new Aadhaar number
    retry: false,
    onSuccess: afterChange,
  });
}

export function useChangeStatus(id: string) {
  const afterChange = useAfterChange();
  return useMutation({
    mutationFn: (input: ChangeStatusInput) => employeesApi.changeStatus(id, input),
    retry: false,
    onSuccess: afterChange,
  });
}

export function useChangeRole(id: string) {
  const afterChange = useAfterChange();
  return useMutation({
    mutationFn: (input: ChangeRoleInput) => employeesApi.changeRole(id, input),
    retry: false,
    onSuccess: afterChange,
  });
}

export function useChangePermissions(id: string) {
  const afterChange = useAfterChange();
  return useMutation({
    mutationFn: (input: ChangePermissionsInput) => employeesApi.changePermissions(id, input),
    retry: false,
    onSuccess: afterChange,
  });
}

/** The full Aadhaar is a mutation result only: never written to the query cache, dropped immediately. */
export function useRevealAadhaar(id: string) {
  return useMutation({
    mutationFn: () => employeesApi.revealAadhaar(id),
    gcTime: 0,
    retry: false,
  });
}
